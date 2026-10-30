import SwiftUI
import AppKit
import WatchdogCore

struct TableRow: Identifiable {
    let position: Position
    let metrics: PositionMetrics?
    let exchange: Exchange?
    let status: ListingStatus?
    let freshness: Freshness?
    /// A corrected ticker, or one that still names another company.
    var notice: ListingNotice? = nil
    var id: UUID { position.id }

    /// Data should be there but is not (source down, throttled, symbol broken, no exchange rate).
    var isStale: Bool { freshness?.isProblem == true }
}

struct Totals {
    var value = 0.0
    /// Purchase cost and current value of the holdings whose purchase price is known.
    var cost = 0.0
    var costedValue = 0.0
    var dayChange = 0.0
    var holdings = 0
    /// Holdings entered without a purchase price (left out of "since purchase").
    var withoutCost = 0
    var counts: [AmpelState: Int] = [:]
    var fresh = 0
    /// Values without current data, with the short reason.
    var stale: [(name: String, headline: String)] = []

    var sincePurchase: Double { costedValue - cost }
    var sincePurchasePercent: Double? { cost > 0 ? (costedValue / cost - 1) * 100 : nil }
    var dayPercent: Double? { value - dayChange > 0 ? (dayChange / (value - dayChange)) * 100 : nil }

    mutating func add(_ r: TableRow) {
        if r.isStale { stale.append((r.position.name, r.freshness?.headline ?? "")) }
        if let m = r.metrics {
            counts[m.ampel.state, default: 0] += 1
            if m.ampel.isFresh { fresh += 1 }
            if !r.position.isWatchOnly, let v = m.valueEUR {
                value += v
                if let c = m.costEUR {
                    cost += c
                    costedValue += v
                } else {
                    withoutCost += 1
                }
                dayChange += m.dayChangeEUR ?? 0
                holdings += 1
            }
        } else {
            counts[.unknown, default: 0] += 1
        }
    }
}

struct TableSection: Identifiable {
    let id: String
    let title: String
    let color: Color?
    let isWatchlist: Bool
    var rows: [TableRow]
    var totals: Totals
}

enum AmpelFilter: Equatable {
    case state(AmpelState)
    case fresh
    case stale
}

/// Asks for confirmation before values are deleted.
enum DeleteRequest: Identifiable, Equatable {
    case positions(Set<UUID>)
    case all

    var id: String {
        switch self {
        case .positions(let ids): return ids.map(\.uuidString).sorted().joined()
        case .all: return "all"
        }
    }
}

enum EditorRequest: Identifiable, Equatable {
    case add(query: String?)
    case edit(UUID)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let u): return u.uuidString
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // Persistent state
    var depot: DepotFile
    private(set) var local: LocalSettings

    // Runtime state
    var snapshot: EngineSnapshot?
    var isRefreshing = false
    var progressDone = 0
    var progressTotal = 0
    var selection: UUID?
    var searchText = ""
    var filter: AmpelFilter?
    var editor: EditorRequest?
    /// The open import dialog (nil = closed).
    var importSession: ImportSession?
    var showImport: Bool { importSession != nil }
    var notice: String?
    /// Rows picked with ⌘ or ⇧ click, for deleting several values at once.
    var marked: Set<UUID> = []
    @ObservationIgnored private var markAnchor: UUID?
    var deleteRequest: DeleteRequest?
    /// Text of the "deleted, undo?" banner; the depot before the delete is kept until then.
    var undoText: String?
    /// What the last delete or group change replaced: the values as they were, and banks and themes if those were removed.
    @ObservationIgnored private var undoPositions: [Position]?
    @ObservationIgnored private var undoGroups: (banks: [Bank], themes: [Theme])?
    var lastSummary: RefreshSummary?
    var isExampleDepot = false
    /// Incremented to ask the main view to open the settings window (used by the screenshot run).
    var settingsRequest = 0
    /// Last heartbeat call: time and error text (nil = ok).
    var heartbeatResult: (date: Date, error: String?)?
    /// Screenshot run only: pretend these listings have gone quiet, to show what an outage looks like.
    var simulatedOutage: [String: Freshness] = [:]

    let engine: MarketEngine
    private(set) var store: DepotStore
    let snapshotDir: URL?
    let notifier = MacNotifier()

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var knownModification: Date?
    /// The depot as last read from or written to the file; saving merges against it (Mac and iPhone edit the same file).
    @ObservationIgnored private var base: DepotFile?
    @ObservationIgnored private var started = false

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // CI screenshot mode: example depot in a throw-away folder.
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            snapshotDir = dir
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-snapshot-\(UUID().uuidString)")
            store = DepotStore(url: tmp.appendingPathComponent("Watchdog.json"))
            if args.contains("--stress") {
                // Layout test with made-up extreme values.
                let (d, provider) = DemoData.stress()
                engine = MarketEngine(cacheDir: tmp.appendingPathComponent("cache"), router: DataRouter(registry: ProviderRegistry([provider])))
                depot = d
            } else {
                engine = MarketEngine(cacheDir: tmp.appendingPathComponent("cache"))
                depot = DepotFile.example()
            }
            var l = LocalSettings()
            l.hasCompletedSetup = true
            local = l
            isExampleDepot = !args.contains("--stress")
            return
        }
        snapshotDir = nil
        let l = LocalSettings.load()
        local = l
        let url = l.depotPath.map { URL(fileURLWithPath: $0) } ?? DepotStore.defaultURL()
        let s = DepotStore(url: url)
        store = s
        engine = MarketEngine(cacheDir: LocalSettings.supportDir.appendingPathComponent("Cache", isDirectory: true))
        if s.exists, let d = try? s.load() {
            depot = d
            base = d
        } else {
            depot = DepotFile()
        }
        knownModification = s.modificationDate()
    }

    // MARK: Lifecycle

    /// The option key is held: the Depot menu shows the hidden test entry.
    var optionHeld = false
    @ObservationIgnored private var flagsMonitor: Any?

    func start() {
        guard !started else { return }
        started = true
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let held = e.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.optionHeld = held }
            return e
        }
        Task {
            await engine.setQuoteInterval(TimeInterval(local.quoteIntervalMinutes * 60))
            await engine.loadCache()
            await recompute()
            refresh(force: snapshotDir != nil)
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.tick()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                self?.refresh(force: false)
            }
        }
        notifier.onOpen = { [weak self] id in
            Task { @MainActor in
                if id == SignalState.dataAlertID {
                    // "Kurse bleiben aus": show the affected values.
                    self?.selection = nil
                    self?.filter = .stale
                } else {
                    self?.selection = id
                }
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })?.makeKeyAndOrderFront(nil)
            }
        }
        if depot.notifications.macEnabled && snapshotDir == nil { notifier.requestAuthorization() }
        applyDockPolicy()
        if let dir = snapshotDir {
            Task { await SnapshotRunner.run(model: self, dir: dir) }
        }
    }

    private func tick() async {
        checkExternalChanges()
        refresh(force: false)
    }

    // MARK: Refresh

    func refresh(force: Bool = false, only: Set<UUID>? = nil) {
        guard !isRefreshing || only != nil else { return }
        if only == nil { isRefreshing = true }
        let depot = self.depot
        let keys = local.keys
        Task { [weak self] in
            guard let self else { return }
            let summary = await engine.refresh(depot: depot, keys: keys, force: force, only: only) { done, total in
                Task { @MainActor [weak self] in
                    self?.progressDone = done
                    self?.progressTotal = total
                }
            }
            await recompute()
            await applyCorrections(snapshot?.corrections ?? [])
            if only == nil {
                isRefreshing = false
                lastSummary = summary
                await heartbeat()
            }
            deliver(summary.events)
        }
    }

    /// Tells an outside monitor that Watchdog is running and online, at most every five minutes.
    /// If these calls stop (Mac off or asleep, app quit, no internet), the monitor sends the alert.
    func heartbeat(force: Bool = false) async {
        guard snapshotDir == nil, let url = depot.notifications.heartbeat else { return }
        if !force, let last = heartbeatResult?.date, Date().timeIntervalSince(last) < 290 { return }
        let error = await engine.heartbeat(url)
        heartbeatResult = (Date(), error)
    }

    func recompute() async {
        let s = await engine.snapshot(depot: depot)
        snapshot = s
    }

    /// The user says the company a source names is this security after all ("Google" and "Alphabet Inc.").
    /// Stored in the depot, so it holds on every Mac and after clearing the cache.
    func confirmCompany(_ p: Position, _ n: ListingNotice) {
        guard let provider = n.provider, let symbol = n.symbol else { return }
        let key = p.listing.key
        let ids = depot.positions.filter { $0.listing.key == key }.map(\.id)
        mutate { d in
            for i in d.positions.indices where d.positions[i].listing.key == key {
                var c = d.positions[i].listing.confirmedSymbols ?? [:]
                c[provider.rawValue] = symbol
                d.positions[i].listing.confirmedSymbols = c
            }
        }
        Task {
            await engine.confirmedCompany(listingKey: key)
            await recompute()
            refresh(force: true, only: Set(ids))
        }
    }

    /// Writes tickers and symbols the engine found wrong (checked through the ISIN) into the depot.
    /// Purchases, groups and everything else of the position stay as they are; the values then load fresh.
    private func applyCorrections(_ list: [ListingCorrection]) async {
        guard !list.isEmpty else { return }
        var ids: Set<UUID> = []
        for c in list {
            let idx = depot.positions.indices.filter { depot.positions[$0].listing.key == c.listingKey }
            guard let first = idx.first else {
                await engine.applied(c, newKey: c.listingKey)
                continue
            }
            let newKey = c.newKey(exchangeID: depot.positions[first].listing.exchangeID)
            mutate { d in
                for i in idx {
                    if let t = c.ticker { d.positions[i].listing.ticker = t }
                    for (k, v) in c.symbols { d.positions[i].listing.symbols[k] = v }
                }
            }
            ids.formUnion(idx.map { depot.positions[$0].id })
            await engine.applied(c, newKey: newKey)
        }
        await recompute()
        if !ids.isEmpty { refresh(force: true, only: ids) }
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await self?.recompute()
        }
    }

    /// Duty for messages among Mac, iPhone and Watch (shared ledger next to the depot).
    private var coordinator = NotificationCoordinator(role: .mac)
    /// Last state of the ledger, for the settings.
    private(set) var ledger: NotificationLedger?
    private var lastLedgerWrite: Date?
    private var lastLedgerHealthy: Bool?

    /// Announces new events. The Mac is first in line; events the iPhone or the Watch announced while the Mac
    /// was asleep are not repeated. Without access to the ledger the Mac simply announces everything.
    private func deliver(_ events: [SignalEvent]) {
        guard snapshotDir == nil else { return }
        var send = events
        if store.exists {
            let healthy = NotificationLedger.healthy(snapshot?.freshness ?? [:])
            // A heartbeat every five minutes is plenty against the 20 minute limit and keeps iCloud quiet.
            let due = events.isEmpty == false || coordinator.pending.isEmpty == false || healthy != lastLedgerHealthy
                || Date().timeIntervalSince(lastLedgerWrite ?? .distantPast) > 5 * 60
            if due {
                let file = LedgerFile(folder: store.url.deletingLastPathComponent())
                let device = Host.current().localizedName ?? "Mac"
                var coord = coordinator
                var copy: NotificationLedger?
                if let d = try? file.update({ (l: inout NotificationLedger) -> NotificationCoordinator.Decision in
                    let d = coord.cycle(ledger: &l, newEvents: events, healthy: healthy, device: device)
                    copy = l
                    return d
                }) {
                    coordinator = coord
                    ledger = copy
                    lastLedgerWrite = Date()
                    lastLedgerHealthy = healthy
                    send = d.deliver
                }
            }
        }
        guard !send.isEmpty else { return }
        if depot.notifications.macEnabled { notifier.post(send) }
        let settings = depot.notifications
        Task { await engine.push(send, settings: settings) }
    }

    /// A message that looks exactly like a real alarm, marked as a test: as a banner on the Mac and over ntfy to iPhone
    /// and Apple Watch. It is not written into the ledger and not into the event log.
    func exampleEvent() -> SignalEvent {
        let catalog = depot.catalog
        let withData = depot.positions.filter { snapshot?.metrics[$0.id]?.hasData == true && catalog[$0.listing.exchangeID] != nil }
        let rule = depot.rules.rules.first { $0.id == RuleSet.crossDownID } ?? RuleSet.defaultRules[0]
        // A value of the depot, preferably one below the line; an invented one while there is no data.
        var position = Position(name: "Beispielwert", listing: Listing(exchangeID: "XETR", ticker: "TEST"))
        var price: Double? = 98.5, line: Double? = 100, distance: Double? = -1.5
        if let p = withData.first(where: { snapshot?.metrics[$0.id]?.ampel.state == .red }) ?? withData.first, let m = snapshot?.metrics[p.id] {
            position = p
            price = m.priceEUR
            distance = m.ampel.distancePercent
            line = nil
            if let lv = m.ampel.lineValue, let pl = m.priceLocal, pl > 0, let pe = m.priceEUR { line = lv * pe / pl }
        }
        let ex = catalog[position.listing.exchangeID] ?? ExchangeCatalog()["XETR"]!
        var e = SignalState.event(id: "test|\(UUID().uuidString)", rule: rule, day: DayKey.today(in: .berlin), position: position,
                                  exchange: ex, priceEUR: price, lineEUR: line, distance: distance)
        e.title = "TEST " + e.title
        e.body += " · Beispiel, kein echtes Signal"
        return e
    }

    func sendExampleNotification() {
        let e = exampleEvent()
        notifier.post([e])
        let settings = depot.notifications
        guard settings.ntfyEnabled else {
            notice = "Beispielmitteilung als Banner auf dem Mac gezeigt. An iPhone und Watch ging nichts, weil ntfy ausgeschaltet ist (Einstellungen > Mitteilungen > \u{201E}Mitteilungen an ntfy senden\u{201C})."
            return
        }
        notice = "Beispielmitteilung wird gesendet …"
        Task {
            do {
                let http = await engine.http
                try await NtfyNotifier(settings: settings, http: http).send(e)
                notice = "Beispielmitteilung gesendet: als Banner auf dem Mac und über ntfy an den Kanal \(settings.ntfyTopic). Auf dem iPhone sollte sie in wenigen Sekunden erscheinen, auf der Watch, wenn das iPhone gesperrt ist."
            } catch {
                notice = "Die Beispielmitteilung kam auf dem Mac an, ntfy hat sie aber nicht angenommen: \(error)"
            }
        }
    }

    /// Reads the ledger again (for the settings).
    func reloadLedger() {
        guard store.exists else { return }
        ledger = LedgerFile(folder: store.url.deletingLastPathComponent()).read()
    }

    // MARK: Depot changes

    func mutate(_ change: (inout DepotFile) -> Void) {
        change(&depot)
        isExampleDepot = false
        scheduleSave()
        scheduleRecompute()
    }

    private func scheduleSave() {
        guard snapshotDir == nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let mine = self.depot
                let written = try self.store.saveMerging(mine, base: self.base)
                self.base = written
                // The iPhone changed something meanwhile: show the merged state.
                if DepotMerge.fileChanged(base: mine, theirs: written) {
                    self.depot = written
                    self.scheduleRecompute()
                }
                self.knownModification = self.store.modificationDate()
            } catch {
                self.notice = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            }
            self.saveTask = nil
        }
    }

    /// Picks up changes another device made to the synced file.
    func checkExternalChanges() {
        guard snapshotDir == nil, saveTask == nil, let mod = store.modificationDate() else { return }
        if let known = knownModification, mod.timeIntervalSince(known) < 1 { return }
        if let d = try? store.load() {
            depot = d
            base = d
            knownModification = mod
            scheduleRecompute()
        }
    }

    func updateLocal(_ change: (inout LocalSettings) -> Void) {
        let old = local
        change(&local)
        guard local != old else { return }
        if snapshotDir == nil { local.save() }
        if old.quoteIntervalMinutes != local.quoteIntervalMinutes {
            let s = TimeInterval(local.quoteIntervalMinutes * 60)
            Task { await engine.setQuoteInterval(s) }
        }
        if old.showInDock != local.showInDock { applyDockPolicy() }
        if old.apiKeys != local.apiKeys { refresh(force: false) }
    }

    func applyDockPolicy() {
        guard snapshotDir == nil else { return }
        NSApp.setActivationPolicy(local.showInDock ? .regular : .accessory)
    }

    // MARK: Positions

    func position(_ id: UUID?) -> Position? { depot.positions.first { $0.id == id } }
    func metrics(_ id: UUID?) -> PositionMetrics? { id.flatMap { snapshot?.metrics[$0] } }
    func freshness(_ p: Position) -> Freshness? { simulatedOutage[p.listing.key] ?? snapshot?.freshness[p.listing.key] }
    func notice(_ p: Position) -> ListingNotice? { snapshot?.notices[p.listing.key].flatMap { $0.isVisible() ? $0 : nil } }

    func add(_ p: Position) {
        mutate { $0.positions.append(p) }
        selection = p.id
        refresh(force: true, only: [p.id])
    }

    func update(_ p: Position) {
        guard let i = depot.positions.firstIndex(where: { $0.id == p.id }) else { return }
        let old = depot.positions[i]
        mutate { $0.positions[i] = p }
        // A new venue or ticker, but also a new ISIN, WKN or name: look the value up again from scratch
        // (the ISIN finds the right symbol, the name is what the sources' answers are checked against).
        if old.listing != p.listing || old.isin != p.isin || old.wkn != p.wkn || old.name != p.name {
            Task {
                await engine.reset(listingKey: old.listing.key)
                await engine.reset(listingKey: p.listing.key)
                refresh(force: true, only: [p.id])
            }
        }
    }

    func delete(_ id: UUID) { remove([id]) }

    // MARK: Selection and deleting

    /// Rows in the order they are shown (collapsed groups left out).
    var visibleOrder: [UUID] {
        sections.filter { !local.collapsedSections.contains($0.id) }.flatMap { $0.rows.map(\.id) }
    }

    /// Click on a row: plain click opens the detail, ⌘ adds or removes a row from the selection, ⇧ selects a range.
    func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if marked.isEmpty, let s = selection, s != id { marked.insert(s) }
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
            markAnchor = id
            selection = nil
        } else if flags.contains(.shift), let anchor = markAnchor ?? selection {
            let order = visibleOrder
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                marked.formUnion(order[min(a, b)...max(a, b)])
                selection = nil
            }
        } else {
            marked = []
            markAnchor = id
            selection = selection == id ? nil : id
        }
    }

    func clearMarks() {
        marked = []
        markAnchor = nil
    }

    /// Delete key or menu: the marked rows, else the open one.
    func requestDeleteSelection() {
        if !marked.isEmpty {
            deleteRequest = .positions(marked)
        } else if let s = selection {
            deleteRequest = .positions([s])
        }
    }

    /// Removes values; until the next delete the previous depot can be restored with `undoDelete()`.
    func remove(_ ids: Set<UUID>, keepGroups: Bool = true) {
        let existing = ids.filter { id in depot.positions.contains { $0.id == id } }
        guard !existing.isEmpty || !keepGroups else { return }
        if snapshotDir == nil { store.backupNow() }
        undoPositions = depot.positions.filter { existing.contains($0.id) }
        undoGroups = keepGroups ? nil : (depot.banks, depot.themes)
        mutate { d in
            d.positions.removeAll { existing.contains($0.id) }
            if !keepGroups {
                d.banks = []
                d.themes = []
            }
        }
        if let s = selection, existing.contains(s) { selection = nil }
        marked.subtract(existing)
        Task { for id in existing { await engine.forget(position: id) } }
        let n = existing.count
        undoText = n == 0 ? "Banken und Themen entfernt." : n == 1 ? "\(depotName(existing.first)) gelöscht." : "\(n) Werte gelöscht."
    }

    func removeAll(keepGroups: Bool) {
        remove(Set(depot.positions.map(\.id)), keepGroups: keepGroups)
    }

    /// Puts back only what the last delete or group change touched, so changes from the iPhone in between stay.
    func undoDelete() {
        guard let old = undoPositions else { return }
        let groups = undoGroups
        undoPositions = nil
        undoGroups = nil
        undoText = nil
        mutate { d in
            for p in old {
                if let i = d.positions.firstIndex(where: { $0.id == p.id }) { d.positions[i] = p } else { d.positions.append(p) }
            }
            if let groups {
                for b in groups.banks where !d.banks.contains(where: { $0.id == b.id }) { d.banks.append(b) }
                for t in groups.themes where !d.themes.contains(where: { $0.id == t.id }) { d.themes.append(t) }
            }
        }
        refresh(force: false)
    }

    private func depotName(_ id: UUID?) -> String {
        undoPositions?.first { $0.id == id }?.name ?? "1 Wert"
    }

    /// Bank or theme for several values at once (selection bar and context menu).
    func assignBank(_ bank: UUID?, to ids: Set<UUID>) {
        let name = bank.flatMap { depot.bank($0)?.name } ?? "Ohne Bank"
        assign(ids, text: "Bank \u{201E}\(name)\u{201C}") { $0.bankID = bank }
    }

    func assignTheme(_ theme: UUID?, to ids: Set<UUID>) {
        let name = theme.flatMap { depot.theme($0)?.name } ?? "Ohne Thema"
        assign(ids, text: "Thema \u{201E}\(name)\u{201C}") { $0.themeID = theme }
    }

    private func assign(_ ids: Set<UUID>, text: String, _ change: (inout Position) -> Void) {
        guard !ids.isEmpty else { return }
        undoPositions = depot.positions.filter { ids.contains($0.id) }
        undoGroups = nil
        mutate { d in
            for i in d.positions.indices where ids.contains(d.positions[i].id) { change(&d.positions[i]) }
        }
        undoText = ids.count == 1 ? "\(text) für 1 Wert gesetzt." : "\(text) für \(ids.count) Werte gesetzt."
    }

    func reloadData(for id: UUID) {
        guard let p = position(id) else { return }
        Task {
            await engine.reset(listingKey: p.listing.key)
            refresh(force: true, only: [id])
        }
    }

    func loadExample() {
        depot = DepotFile.example()
        isExampleDepot = true
        scheduleRecompute()
        refresh(force: true)
    }

    func startEmpty() {
        depot = DepotFile()
        isExampleDepot = false
        scheduleSave()
        scheduleRecompute()
    }

    func openImport() {
        if importSession == nil { importSession = ImportSession(model: self) }
    }

    // MARK: Storage

    var storagePath: String { store.url.path }

    func moveStorage(to folder: URL) {
        let target = folder.appendingPathComponent("Watchdog.json")
        let newStore = DepotStore(url: target)
        do {
            try newStore.save(depot)
            base = try? newStore.load()
            store = newStore
            knownModification = newStore.modificationDate()
            updateLocal { $0.depotPath = target.path }
            notice = "Depot wird jetzt hier gespeichert: \(folder.path)"
        } catch {
            notice = "Ordner nicht beschreibbar: \(error.localizedDescription)"
        }
    }

    /// Opens an existing Watchdog.json (e.g. from another Mac).
    func openDepot(at url: URL) {
        let s = DepotStore(url: url)
        do {
            depot = try s.load()
            base = depot
            store = s
            knownModification = s.modificationDate()
            updateLocal { $0.depotPath = url.path }
            isExampleDepot = false
            scheduleRecompute()
            refresh(force: true)
        } catch {
            notice = "Datei nicht lesbar: \(error.localizedDescription)"
        }
    }

    func restoreBackup(_ url: URL) {
        guard let d = try? DepotStore(url: url).load() else {
            notice = "Sicherung nicht lesbar."
            return
        }
        mutate { $0 = d }
        notice = "Sicherung vom \(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Watchdog_", with: "")) wiederhergestellt."
    }

    var backups: [URL] { store.backups() }

    // MARK: Table

    var catalog: ExchangeCatalog { depot.catalog }

    func row(_ p: Position) -> TableRow {
        TableRow(position: p, metrics: snapshot?.metrics[p.id], exchange: catalog[p.listing.exchangeID], status: snapshot?.status[p.listing.key],
                 freshness: simulatedOutage[p.listing.key] ?? snapshot?.freshness[p.listing.key],
                 notice: notice(p))
    }

    var allRows: [TableRow] { depot.positions.map(row) }

    var totals: Totals {
        var t = Totals()
        for r in allRows { t.add(r) }
        return t
    }

    private func matches(_ r: TableRow) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hay = [r.position.name, r.position.isin ?? "", r.position.wkn ?? "", r.position.listing.ticker, r.exchange?.name ?? ""]
            if !hay.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return false }
        }
        switch filter {
        case .none: return true
        case .state(let s): return (r.metrics?.ampel.state ?? .unknown) == s
        case .fresh: return r.metrics?.ampel.isFresh == true
        case .stale: return r.isStale
        }
    }

    private func sorted(_ rows: [TableRow]) -> [TableRow] {
        let key = local.sort
        let asc = local.sortAscending
        func val(_ r: TableRow) -> Double? {
            guard let m = r.metrics else { return nil }
            switch key {
            case .value: return m.valueEUR
            case .day: return m.dayChangePercent
            case .sincePurchase: return m.sincePurchasePercent
            case .ytd: return m.ytdPercent
            case .days30: return m.days30Percent
            case .distance: return m.ampel.distancePercent
            default: return nil
            }
        }
        return rows.sorted { a, b in
            switch key {
            case .name:
                let r = a.position.name.localizedStandardCompare(b.position.name) == .orderedAscending
                return asc ? r : !r
            case .signal:
                let ua = a.metrics?.ampel.state.urgency ?? 3, ub = b.metrics?.ampel.state.urgency ?? 3
                if ua != ub { return asc ? ua < ub : ua > ub }
                let fa = a.metrics?.ampel.isFresh == true, fb = b.metrics?.ampel.isFresh == true
                if fa != fb { return fa }
                let da = a.metrics?.ampel.distancePercent ?? 999, db = b.metrics?.ampel.distancePercent ?? 999
                if da != db { return asc ? da < db : da > db }
                return a.position.name.localizedStandardCompare(b.position.name) == .orderedAscending
            default:
                // Missing values always go last.
                switch (val(a), val(b)) {
                case let (x?, y?): return asc ? x < y : x > y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.position.name.localizedStandardCompare(b.position.name) == .orderedAscending
                }
            }
        }
    }

    var sections: [TableSection] {
        let rows = allRows.filter(matches)
        var out: [TableSection] = []
        func make(_ id: String, _ title: String, _ color: Color?, watch: Bool, _ list: [TableRow]) {
            guard !list.isEmpty else { return }
            var t = Totals()
            for r in list { t.add(r) }
            out.append(TableSection(id: id, title: title, color: color, isWatchlist: watch, rows: sorted(list), totals: t))
        }
        switch local.grouping {
        case .bank:
            let holdings = rows.filter { !$0.position.isWatchOnly }
            for b in depot.banks.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                make("bank-\(b.id)", b.name, nil, watch: false, holdings.filter { $0.position.bankID == b.id })
            }
            let known = Set(depot.banks.map(\.id))
            make("bank-none", "Ohne Bank", nil, watch: false, holdings.filter { $0.position.bankID == nil || !known.contains($0.position.bankID!) })
            make("watch", "Beobachtung", nil, watch: true, rows.filter { $0.position.isWatchOnly })
        case .theme:
            for t in depot.themes.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                make("theme-\(t.id)", t.name, Color(hexString: t.color), watch: false, rows.filter { $0.position.themeID == t.id })
            }
            let known = Set(depot.themes.map(\.id))
            make("theme-none", "Ohne Thema", nil, watch: false, rows.filter { $0.position.themeID == nil || !known.contains($0.position.themeID!) })
        case .none:
            make("all", "Alle Werte", nil, watch: false, rows)
        }
        return out
    }

    func toggleSort(_ key: SortKey) {
        updateLocal { l in
            if l.sort == key { l.sortAscending.toggle() } else {
                l.sort = key
                l.sortAscending = key == .name || key == .signal || key == .distance
            }
        }
    }

    func toggleSection(_ id: String) {
        updateLocal { l in
            if l.collapsedSections.contains(id) { l.collapsedSections.remove(id) } else { l.collapsedSections.insert(id) }
        }
    }

    // MARK: Groups

    @discardableResult
    func addBank(_ name: String) -> UUID {
        let b = Bank(name: name, sortIndex: (depot.banks.map(\.sortIndex).max() ?? -1) + 1)
        mutate { $0.banks.append(b) }
        return b.id
    }

    @discardableResult
    func addTheme(_ name: String) -> UUID {
        let palette = ["#7FA34B", "#8A6A4A", "#C9A227", "#4E7AA8", "#9B5DA8", "#3E9A93", "#B5533C", "#6C7A89"]
        let t = Theme(name: name, sortIndex: (depot.themes.map(\.sortIndex).max() ?? -1) + 1, color: palette[depot.themes.count % palette.count])
        mutate { $0.themes.append(t) }
        return t.id
    }

    var lastRefreshText: String {
        guard let d = snapshot?.lastRefresh else { return "noch nicht aktualisiert" }
        return "Stand " + Format.time(d)
    }
}
