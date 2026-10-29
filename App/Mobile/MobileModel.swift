import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import WatchdogCore

/// Central state of the iPhone and iPad app: the depot from iCloud Drive, prices, notifications and the link to the Watch.
/// The depot is only read here; values are added and edited on the Mac.
@MainActor
@Observable
final class MobileModel {
    enum Grouping: String, CaseIterable, Identifiable {
        case bank = "Banken", theme = "Themen", list = "Liste"
        var id: String { rawValue }
    }

    struct ListSection: Identifiable {
        let id: String
        let title: String
        let color: Color?
        let positions: [Position]
    }

    /// Same as in Info.plist ("<bundle id>.check"), so it also fits when the app is built under another id for a personal Apple ID.
    static let backgroundTaskID = (Bundle.main.bundleIdentifier ?? "de.realrusher.watchdog") + ".check"

    var depot = DepotFile()
    var snapshot: EngineSnapshot?
    var folder: URL?
    var depotError: String?
    var isRefreshing = false
    var selection: UUID?
    var showSettings = false
    var ledger: NotificationLedger?
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var grouping: Grouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "grouping") }
    }

    /// Screenshot runs in CI: example depot with live prices, no iCloud, no notifications.
    let isDemo: Bool
    let engine: MarketEngine
    let watch = WatchLink()
    private var coordinator: NotificationCoordinator
    private var started = false
    private var loop: Task<Void, Never>?

    init() {
        let args = ProcessInfo.processInfo.arguments
        isDemo = args.contains("--demo")
        grouping = Grouping(rawValue: UserDefaults.standard.string(forKey: "grouping") ?? "") ?? .bank
        if let i = args.firstIndex(of: "--grouping"), i + 1 < args.count, let g = Grouping(rawValue: args[i + 1]) { grouping = g }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Watchdog", isDirectory: true)
        engine = MarketEngine(cacheDir: caches)
        coordinator = Self.loadCoordinator() ?? NotificationCoordinator(role: .iphone)
        if isDemo {
            depot = DepotFile.example()
        } else {
            folder = DepotAccess.restore()
        }
        watch.onReport = { [weak self] ids, heartbeat in
            Task { @MainActor in self?.mergeFromWatch(ids, heartbeat) }
        }
    }

    var needsFolder: Bool { !isDemo && folder == nil }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Task {
            await engine.loadCache()
            readDepot()
            await recompute()
            await refresh()
            if isDemo, ProcessInfo.processInfo.arguments.contains("--open-first") {
                selection = depot.positions.first { snapshot?.metrics[$0.id]?.ampel.state == .red }?.id ?? depot.positions.first?.id
            }
        }
        if !isDemo { requestNotifications() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.refresh()
            }
        }
    }

    func becameActive() {
        Task {
            readDepot()
            await refresh()
            await refreshNotificationStatus()
        }
    }

    func chooseFolder(_ url: URL) {
        do {
            try DepotAccess.remember(url)
            folder = url
            depot = try DepotAccess.readDepot(in: url)
            depotError = nil
            Task {
                await recompute()
                await refresh(force: true)
            }
        } catch {
            depotError = error.localizedDescription
            folder = nil
            DepotAccess.forget()
        }
    }

    /// Reads the depot again; the Mac may have changed it.
    func readDepot() {
        guard !isDemo, let folder else { return }
        do {
            let d = try DepotAccess.readDepot(in: folder)
            if d.modifiedAt != depot.modifiedAt || d.positions.count != depot.positions.count { depot = d }
            depotError = nil
        } catch {
            depotError = error.localizedDescription
        }
    }

    // MARK: Prices

    func refresh(force: Bool = false) async {
        guard !isRefreshing, !needsFolder else { return }
        isRefreshing = true
        let summary = await engine.refresh(depot: depot, keys: [:], force: force)
        await recompute()
        isRefreshing = false
        announce(summary.events)
        sendToWatch()
    }

    func recompute() async {
        snapshot = await engine.snapshot(depot: depot)
    }

    /// Called by iOS now and then while the app is in the background. iOS decides when; it may be minutes or hours.
    func backgroundCheck() async {
        scheduleBackgroundCheck()
        if !started {
            await engine.loadCache()
            readDepot()
        }
        await refresh()
    }

    func scheduleBackgroundCheck() {
        guard !isDemo else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        r.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    // MARK: Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in await self.refreshNotificationStatus() }
        }
    }

    func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Writes the heartbeat into the ledger and announces what the Mac did not (the iPhone only steps in when the Mac stops).
    private func announce(_ events: [SignalEvent]) {
        guard !isDemo, let folder else { return }
        let healthy = NotificationLedger.healthy(snapshot?.freshness ?? [:])
        var coord = coordinator
        let device = UIDevice.current.name
        guard let result = DepotAccess.updateLedger(in: folder, { (l: inout NotificationLedger) in
            coord.cycle(ledger: &l, newEvents: events, healthy: healthy, device: device)
        }) else { return }
        let decision = result.0
        coordinator = coord
        ledger = result.1
        Self.saveCoordinator(coord)
        guard depot.notifications.macEnabled else { return }
        for e in decision.deliver { post(e) }
    }

    private func post(_ e: SignalEvent) {
        let c = UNMutableNotificationContent()
        c.title = e.title
        c.body = e.body
        c.sound = .default
        // Alarms break through a focus mode once the app carries the time sensitive capability (Apple account).
        c.interruptionLevel = e.severity == .alarm ? .timeSensitive : .active
        c.userInfo = ["position": e.positionID.uuidString]
        c.threadIdentifier = e.positionID.uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id, content: c, trigger: nil))
    }

    private func mergeFromWatch(_ ids: [String], _ heartbeat: NotificationLedger.Checker?) {
        guard !isDemo, let folder else { return }
        if let result = DepotAccess.updateLedger(in: folder, { (l: inout NotificationLedger) in
            l.record(ids, by: .watch)
            if let h = heartbeat, (l.checkers[.watch]?.lastCheck ?? .distantPast) < h.lastCheck { l.checkers[.watch] = h }
        }) {
            ledger = result.1
        }
    }

    func reloadLedger() {
        guard let folder else { return }
        ledger = DepotAccess.updateLedger(in: folder, { (_: inout NotificationLedger) in () })?.1
    }

    private static let coordinatorKey = "notificationCoordinator"

    private static func loadCoordinator() -> NotificationCoordinator? {
        UserDefaults.standard.data(forKey: coordinatorKey).flatMap { try? DepotStore.decoder().decode(NotificationCoordinator.self, from: $0) }
    }

    private static func saveCoordinator(_ c: NotificationCoordinator) {
        if let d = try? DepotStore.encoder().encode(c) { UserDefaults.standard.set(d, forKey: coordinatorKey) }
    }

    // MARK: Watch

    private func sendToWatch() {
        guard let snapshot, watch.isWatchAppInstalled else { return }
        let depot = self.depot, ledger = self.ledger ?? NotificationLedger()
        Task {
            let symbols = await engine.knownSymbols()
            watch.send(WatchSnapshot.make(depot: depot, snapshot: snapshot, ledger: ledger, symbols: symbols))
        }
    }

    // MARK: Navigation

    /// "watchdog://wert/<id>" from a notification or from ntfy.
    func open(_ url: URL) {
        guard url.scheme == "watchdog", let id = UUID(uuidString: url.lastPathComponent) else { return }
        selection = id
    }

    // MARK: Table data

    var catalog: ExchangeCatalog { depot.catalog }

    func metrics(_ id: UUID?) -> PositionMetrics? { id.flatMap { snapshot?.metrics[$0] } }
    func position(_ id: UUID?) -> Position? { depot.positions.first { $0.id == id } }
    func freshness(_ p: Position) -> Freshness? { snapshot?.freshness[p.listing.key] }
    func notice(_ p: Position) -> ListingNotice? { snapshot?.notices[p.listing.key].flatMap { $0.isVisible() ? $0 : nil } }

    /// Below the line first, then by distance: the order the customer looks at.
    private func sorted(_ list: [Position]) -> [Position] {
        list.sorted { a, b in
            let da = metrics(a.id)?.ampel.distancePercent ?? .infinity, db = metrics(b.id)?.ampel.distancePercent ?? .infinity
            return da < db
        }
    }

    var sections: [ListSection] {
        let all = depot.positions
        switch grouping {
        case .list:
            return [ListSection(id: "all", title: "Alle Werte", color: nil, positions: sorted(all))]
        case .bank:
            let holdings = all.filter { !$0.isWatchOnly }
            var out = depot.banks.sorted { $0.sortIndex < $1.sortIndex }.map { b in
                ListSection(id: "bank-\(b.id)", title: b.name, color: nil, positions: sorted(holdings.filter { $0.bankID == b.id }))
            }
            let known = Set(depot.banks.map(\.id))
            out.append(ListSection(id: "bank-none", title: "Ohne Bank", color: nil,
                               positions: sorted(holdings.filter { $0.bankID == nil || !known.contains($0.bankID!) })))
            out.append(ListSection(id: "watch", title: "Beobachtung", color: nil, positions: sorted(all.filter(\.isWatchOnly))))
            return out.filter { !$0.positions.isEmpty }
        case .theme:
            var out = depot.themes.sorted { $0.sortIndex < $1.sortIndex }.map { t in
                ListSection(id: "theme-\(t.id)", title: t.name, color: Color(hexString: t.color), positions: sorted(all.filter { $0.themeID == t.id }))
            }
            let known = Set(depot.themes.map(\.id))
            out.append(ListSection(id: "theme-none", title: "Ohne Thema", color: nil,
                               positions: sorted(all.filter { $0.themeID == nil || !known.contains($0.themeID!) })))
            return out.filter { !$0.positions.isEmpty }
        }
    }

    struct Totals {
        var value = 0.0, cost = 0.0, costedValue = 0.0, dayChange = 0.0
        var holdings = 0
        var counts: [AmpelState: Int] = [:]
        var fresh = 0
        var stale: [String] = []
        var sincePurchase: Double { costedValue - cost }
        var sincePurchasePercent: Double? { cost > 0 ? (costedValue / cost - 1) * 100 : nil }
        var dayPercent: Double? { value - dayChange > 0 ? dayChange / (value - dayChange) * 100 : nil }
    }

    var totals: Totals {
        var t = Totals()
        for p in depot.positions {
            if freshness(p)?.isProblem == true { t.stale.append(p.name) }
            guard let m = metrics(p.id) else { t.counts[.unknown, default: 0] += 1; continue }
            t.counts[m.ampel.state, default: 0] += 1
            if m.ampel.isFresh { t.fresh += 1 }
            if !p.isWatchOnly, let v = m.valueEUR {
                t.value += v
                t.holdings += 1
                t.dayChange += m.dayChangeEUR ?? 0
                if let c = m.costEUR { t.cost += c; t.costedValue += v }
            }
        }
        return t
    }
}

/// Opens the value of a tapped notification.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var open: (@Sendable (UUID) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["position"] as? String, let id = UUID(uuidString: s) { open?(id) }
    }
}
