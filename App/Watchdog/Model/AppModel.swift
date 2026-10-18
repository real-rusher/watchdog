import SwiftUI
import AppKit
import WatchdogCore

struct TableRow: Identifiable {
    let position: Position
    let metrics: PositionMetrics?
    let exchange: Exchange?
    let status: ListingStatus?
    var id: UUID { position.id }
}

struct Totals {
    var value = 0.0
    var cost = 0.0
    var dayChange = 0.0
    var holdings = 0
    var counts: [AmpelState: Int] = [:]
    var fresh = 0

    var sincePurchase: Double { value - cost }
    var sincePurchasePercent: Double? { cost > 0 ? (value / cost - 1) * 100 : nil }
    var dayPercent: Double? { value - dayChange > 0 ? (dayChange / (value - dayChange)) * 100 : nil }

    mutating func add(_ r: TableRow) {
        if let m = r.metrics {
            counts[m.ampel.state, default: 0] += 1
            if m.ampel.isFresh { fresh += 1 }
            if !r.position.isWatchOnly, let v = m.valueEUR {
                value += v
                cost += m.costEUR ?? 0
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
    var showImport = false
    var notice: String?
    var lastSummary: RefreshSummary?
    var isExampleDepot = false
    /// Incremented to ask the main view to open the settings window (used by the screenshot run).
    var settingsRequest = 0

    let engine: MarketEngine
    private(set) var store: DepotStore
    let snapshotDir: URL?
    let notifier = MacNotifier()

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var knownModification: Date?
    @ObservationIgnored private var started = false

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // CI screenshot mode: example depot in a throw-away folder.
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            snapshotDir = dir
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-snapshot-\(UUID().uuidString)")
            store = DepotStore(url: tmp.appendingPathComponent("Watchdog.json"))
            engine = MarketEngine(cacheDir: tmp.appendingPathComponent("cache"))
            depot = DepotFile.example()
            var l = LocalSettings()
            l.hasCompletedSetup = true
            local = l
            isExampleDepot = true
            return
        }
        snapshotDir = nil
        let l = LocalSettings.load()
        local = l
        let url = l.depotPath.map { URL(fileURLWithPath: $0) } ?? DepotStore.defaultURL()
        store = DepotStore(url: url)
        engine = MarketEngine(cacheDir: LocalSettings.supportDir.appendingPathComponent("Cache", isDirectory: true))
        if store.exists, let d = try? store.load() {
            depot = d
        } else {
            depot = DepotFile()
        }
        knownModification = store.modificationDate()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
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
                self?.selection = id
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
            if only == nil {
                isRefreshing = false
                lastSummary = summary
            }
            deliver(summary.events)
        }
    }

    func recompute() async {
        let s = await engine.snapshot(depot: depot)
        snapshot = s
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await self?.recompute()
        }
    }

    private func deliver(_ events: [SignalEvent]) {
        guard !events.isEmpty, snapshotDir == nil else { return }
        if depot.notifications.macEnabled { notifier.post(events) }
        let settings = depot.notifications
        Task { await engine.push(events, settings: settings) }
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
                try self.store.save(self.depot)
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

    func add(_ p: Position) {
        mutate { $0.positions.append(p) }
        selection = p.id
        refresh(force: true, only: [p.id])
    }

    func update(_ p: Position) {
        guard let i = depot.positions.firstIndex(where: { $0.id == p.id }) else { return }
        let old = depot.positions[i]
        mutate { $0.positions[i] = p }
        if old.listing != p.listing {
            Task {
                await engine.reset(listingKey: old.listing.key)
                await engine.reset(listingKey: p.listing.key)
                refresh(force: true, only: [p.id])
            }
        }
    }

    func delete(_ id: UUID) {
        mutate { $0.positions.removeAll { $0.id == id } }
        if selection == id { selection = nil }
        Task { await engine.forget(position: id) }
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

    // MARK: Storage

    var storagePath: String { store.url.path }

    func moveStorage(to folder: URL) {
        let target = folder.appendingPathComponent("Watchdog.json")
        let newStore = DepotStore(url: target)
        do {
            try newStore.save(depot)
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
        TableRow(position: p, metrics: snapshot?.metrics[p.id], exchange: catalog[p.listing.exchangeID], status: snapshot?.status[p.listing.key])
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
