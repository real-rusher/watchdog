import SwiftUI
import WatchKit
import WatchConnectivity
import UserNotifications
import WidgetKit
import WatchdogCore

/// Watch side of the connection: receives the iPhone's reading, reports what the Watch announced.
final class WatchSession: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onSnapshot: (@Sendable (Data) -> Void)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var lastContext: Data? { WCSession.isSupported() ? WCSession.default.receivedApplicationContext["snapshot"] as? Data : nil }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let d = session.receivedApplicationContext["snapshot"] as? Data { onSnapshot?(d) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let d = applicationContext["snapshot"] as? Data { onSnapshot?(d) }
    }

    /// Delivered in the background as soon as the iPhone is reachable; the iPhone writes it into the shared ledger.
    func report(_ ids: [String], heartbeat: NotificationLedger.Checker) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var info: [String: Any] = ["reported": ids]
        if let d = try? DepotStore.encoder().encode(heartbeat) { info["heartbeat"] = d }
        WCSession.default.transferUserInfo(info)
    }
}

@MainActor
@Observable
final class WatchModel {
    var snapshot: WatchSnapshot?
    var isChecking = false
    var lastOwnCheck: Date?

    /// Screenshot runs: the example depot evaluated on the Watch itself, with live prices.
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    private let session = WatchSession()
    private var coordinator: NotificationCoordinator
    private var started = false
    /// Rows further away from the line than this cannot cross it in one day; they are not fetched (battery).
    static let checkBand = 10.0
    static let maxRows = 30

    init() {
        coordinator = UserDefaults.standard.data(forKey: "coordinator").flatMap { try? DepotStore.decoder().decode(NotificationCoordinator.self, from: $0) }
            ?? NotificationCoordinator(role: .watch)
        session.onSnapshot = { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if isDemo {
            Task { await loadDemo() }
            return
        }
        snapshot = SnapshotStore.load()
        if let d = session.lastContext { receive(d) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleBackgroundCheck()
    }

    private func receive(_ data: Data) {
        guard let s = try? WatchSnapshot.decode(data) else { return }
        // Keep what the Watch learned in between (its own prices) only if the iPhone's reading is older.
        if let mine = snapshot, mine.createdAt > s.createdAt { return }
        snapshot = s
        SnapshotStore.save(s)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Checking

    /// Opened by the user: show current prices when the iPhone's reading is older than a quarter of an hour.
    func refreshIfOld() async {
        guard let s = snapshot, Date().timeIntervalSince(lastOwnCheck ?? s.createdAt) > 15 * 60 else { return }
        await check(force: true)
    }

    /// watchOS wakes the app now and then. The Watch only checks when neither Mac nor iPhone did for 20 minutes.
    func backgroundCheck() async {
        scheduleBackgroundCheck()
        if snapshot == nil { snapshot = SnapshotStore.load() }
        await check(force: false)
    }

    func scheduleBackgroundCheck() {
        guard !isDemo else { return }
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(15 * 60), userInfo: "check" as NSString) { _ in }
    }

    func check(force: Bool) async {
        guard var s = snapshot, !isChecking else { return }
        let duty = s.ledger.onDuty(asking: .watch)
        guard force || duty == .watch else { return }
        isChecking = true
        defer { isChecking = false }

        let candidates = s.rows
            .filter { $0.line != nil && abs($0.distance ?? 0) <= Self.checkBand }
            .sorted { abs($0.distance ?? 0) < abs($1.distance ?? 0) }
            .prefix(Self.maxRows)
        let quotes = await Self.fetch(Array(candidates), snapshot: s)
        let catalog = s.catalog
        var events: [SignalEvent] = []
        for i in s.rows.indices {
            guard let q = quotes[s.rows[i].id], let ex = catalog[s.rows[i].listing.exchangeID] else { continue }
            events += WatchCheck.apply(q, to: &s.rows[i], snapshot: s, exchange: ex)
        }
        lastOwnCheck = Date()

        // Announce only when on duty; the events stay pending otherwise and the Mac or iPhone report them.
        var ledger = s.ledger
        let healthy = candidates.isEmpty || !quotes.isEmpty
        let decision = coordinator.cycle(ledger: &ledger, newEvents: events, healthy: healthy, device: WKInterfaceDevice.current().name)
        s.ledger = ledger
        if let d = try? DepotStore.encoder().encode(coordinator) { UserDefaults.standard.set(d, forKey: "coordinator") }
        if !isDemo {
            for e in decision.deliver { post(e) }
            if let me = ledger.checkers[.watch] { session.report(decision.deliver.map(\.id), heartbeat: me) }
        }
        snapshot = s
        SnapshotStore.save(s)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func post(_ e: SignalEvent) {
        let c = UNMutableNotificationContent()
        c.title = e.title
        c.body = e.body
        c.sound = .default
        c.interruptionLevel = e.severity == .alarm ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id, content: c, trigger: nil))
    }

    /// Current prices for the given rows, a few at a time; symbols come from the iPhone, so no searching on the Watch.
    nonisolated static func fetch(_ rows: [WatchSnapshot.Row], snapshot: WatchSnapshot) async -> [UUID: Quote] {
        let router = DataRouter()
        let env = ProviderEnvironment(http: HTTPClient(), keys: [:], catalog: snapshot.catalog)
        let prefs = snapshot.sources
        return await withTaskGroup(of: (UUID, Quote?).self) { group in
            for r in rows {
                guard let ex = env.catalog[r.listing.exchangeID] else { continue }
                group.addTask {
                    let o = await router.first(.quote, what: "quote", ref: SecurityRef(r.position), exchange: ex, prefs: prefs, env: env, symbols: nil) { p, sym in
                        try await p.quote(symbol: sym, exchange: ex, env: env)
                    }
                    return (r.id, o.value)
                }
            }
            var out: [UUID: Quote] = [:]
            for await (id, q) in group { if let q { out[id] = q } }
            return out
        }
    }

    // MARK: Demo

    private func loadDemo() async {
        let depot = DepotFile.example()
        let engine = MarketEngine(cacheDir: nil)
        _ = await engine.refresh(depot: depot, keys: [:], force: true)
        let snap = await engine.snapshot(depot: depot)
        var ledger = NotificationLedger()
        ledger.heartbeat(.mac, healthy: true, device: "Mac")
        snapshot = WatchSnapshot.make(depot: depot, snapshot: snap, ledger: ledger, symbols: await engine.knownSymbols())
    }
}
