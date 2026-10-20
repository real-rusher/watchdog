import SwiftUI
import WatchdogCore

/// State and logic of one import, separate from the dialog so it can be driven by the screenshot run as well.
@MainActor
@Observable
final class ImportSession: Identifiable {
    let id = UUID()

    enum RowState {
        case waiting
        case searching
        case found(ImportResolver.Choice)
        case notFound(String)

        var choice: ImportResolver.Choice? { if case .found(let c) = self { return c } else { return nil } }
    }

    struct Result {
        var added: [String] = []
        var extended: [String] = []
        var notFound: [String] = []
        var fxMissing: [String] = []
    }

    // Input
    var text = ""
    var sourceName: String?
    var sheets: [ImportFile.Sheet] = []
    var sheetIndex = 0
    var error: String?

    // Parsed
    var table: CSVImport.Table?
    var mapping: [CSVImport.Field] = []
    var drafts: [CSVImport.Draft] = []
    var states: [UUID: RowState] = [:]
    var defaultExchange: ExchangeID

    // Progress
    var resolving = false
    var resolvedCount = 0
    var committing = false
    var result: Result?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var searchCache: [String: [SearchCandidate]] = [:]
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: [CSVImport.Draft] = []

    init(model: AppModel) {
        self.model = model
        defaultExchange = model.local.defaultImportExchange
    }

    // MARK: Input

    func load(url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Numbers documents can be folders (packages).
            error = ImportFile.ReadError.numbers.localizedDescription
            return
        }
        do {
            let data = try Data(contentsOf: url)
            sourceName = url.lastPathComponent
            use(try ImportFile.sheets(data: data, filename: url.lastPathComponent))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func load(text: String, name: String? = nil) {
        self.text = text
        sourceName = name
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        use([ImportFile.Sheet(name: name ?? "Eingefügt", rows: CSVImport.rows(text))])
    }

    private func use(_ s: [ImportFile.Sheet]) {
        error = nil
        result = nil
        sheets = s
        let best = CSVImport.bestTable(s)
        sheetIndex = s.firstIndex { $0.name == best.sheetName } ?? 0
        apply(best)
    }

    func selectSheet(_ i: Int) {
        guard sheets.indices.contains(i) else { return }
        sheetIndex = i
        apply(CSVImport.table(rows: sheets[i].rows, sheetName: sheets[i].name))
    }

    private func apply(_ t: CSVImport.Table) {
        table = t
        mapping = CSVImport.guessMapping(t.headers, rows: t.rows)
        if t.rows.isEmpty { error = "In der Tabelle wurden keine Zeilen gefunden." }
        rebuild()
    }

    func setField(_ field: CSVImport.Field, column: Int) {
        guard column < mapping.count else { return }
        // Each field once: the column that had it before loses it.
        if field != .ignore, let other = mapping.firstIndex(of: field), other != column { mapping[other] = .ignore }
        mapping[column] = field
        rebuild()
    }

    func setDefaultExchange(_ id: ExchangeID) {
        defaultExchange = id
        model?.updateLocal { $0.defaultImportExchange = id }
        startResolving()
    }

    private func rebuild() {
        guard let t = table, let model else { return }
        drafts = CSVImport.drafts(t, mapping: mapping, catalog: model.catalog)
        states = [:]
        startResolving()
    }

    // MARK: Resolve

    /// Starts (or restarts) the search for all rows; search results are cached, so a restart is cheap.
    func startResolving() {
        resolveTask?.cancel()
        generation += 1
        let gen = generation
        resolveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.resolveAll(generation: gen)
        }
    }

    func waitUntilResolved() async {
        while resolveTask != nil || resolving { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    private func resolveAll(generation gen: Int) async {
        guard let model else { return }
        pending = drafts
        resolving = true
        resolvedCount = 0
        let catalog = model.catalog
        let target = defaultExchange
        // Four rows at a time: fast enough for 100 values without hammering the sources.
        var workers: [Task<Void, Never>] = []
        for _ in 0..<4 {
            workers.append(Task { @MainActor [weak self] in
                while let self, gen == self.generation, !self.pending.isEmpty {
                    let d = self.pending.removeFirst()
                    self.states[d.id] = .searching
                    let outcome = await ImportResolver.resolve(d, target: target, catalog: catalog) { q in
                        await self.search(q)
                    }
                    guard gen == self.generation else { return }
                    switch outcome {
                    case .found(let c): self.states[d.id] = .found(c)
                    case .notFound(let m): self.states[d.id] = .notFound(m)
                    }
                    self.resolvedCount += 1
                }
            })
        }
        for w in workers { await w.value }
        if gen == generation {
            resolving = false
            resolveTask = nil
        }
    }

    private func search(_ q: String) async -> [SearchCandidate] {
        if let c = searchCache[q] { return c }
        guard let model else { return [] }
        let r = await model.engine.search(q, depot: model.depot, keys: model.local.keys)
        if !r.isEmpty { searchCache[q] = r }
        return r
    }

    func choose(_ option: ListingOption, for id: UUID) {
        guard case .found(var c) = states[id] else { return }
        c.option = option
        c.note = nil
        states[id] = .found(c)
    }

    func toggle(_ id: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[i].include.toggle()
    }

    var foundCount: Int { drafts.filter { $0.include && states[$0.id]?.choice != nil }.count }
    var includedCount: Int { drafts.filter(\.include).count }

    /// Position already in the depot at the same venue.
    func existing(_ d: CSVImport.Draft) -> Position? {
        guard let model, let c = states[d.id]?.choice else { return nil }
        let key = c.option.listing().key
        return model.depot.positions.first { $0.listing.key == key || ($0.isin != nil && $0.isin == (d.isin ?? c.option.isin) && $0.listing.exchangeID == c.option.exchangeID) }
    }

    // MARK: Commit

    func commit() async {
        guard let model, !committing else { return }
        committing = true
        defer { committing = false }
        var r = Result()
        var newPositions: [Position] = []
        var extendLots: [UUID: [Lot]] = [:]
        var banks = model.depot.banks
        var themes = model.depot.themes
        let today = DayKey.today(in: .berlin)

        for d in drafts where d.include {
            guard let c = states[d.id]?.choice else {
                r.notFound.append(d.name)
                continue
            }
            var lots: [Lot] = []
            for l in d.lots {
                let day = l.day ?? today
                var cost = 0.0
                if let raw = l.cost {
                    if let rate = await model.engine.eurRate(l.currency, on: day) {
                        cost = raw * rate
                    } else {
                        r.fxMissing.append(d.name)
                    }
                }
                lots.append(Lot(day: day, quantity: l.quantity, totalCostEUR: (cost * 100).rounded() / 100))
            }
            var bankID: UUID?
            if let b = d.bank?.trimmingCharacters(in: .whitespaces), !b.isEmpty {
                if let found = banks.first(where: { $0.name.caseInsensitiveCompare(b) == .orderedSame }) {
                    bankID = found.id
                } else {
                    let nb = Bank(name: b, sortIndex: (banks.map(\.sortIndex).max() ?? -1) + 1)
                    banks.append(nb)
                    bankID = nb.id
                }
            }
            var themeID: UUID?
            if let t = d.theme?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
                if let found = themes.first(where: { $0.name.caseInsensitiveCompare(t) == .orderedSame }) {
                    themeID = found.id
                } else {
                    let palette = ["#7FA34B", "#8A6A4A", "#C9A227", "#4E7AA8", "#9B5DA8", "#3E9A93", "#B5533C", "#6C7A89"]
                    let nt = Theme(name: t, sortIndex: (themes.map(\.sortIndex).max() ?? -1) + 1, color: palette[themes.count % palette.count])
                    themes.append(nt)
                    themeID = nt.id
                }
            }
            if let old = existing(d) {
                // Same security already there: add the purchases that are new.
                let fresh = lots.filter { l in !old.lots.contains { $0.day == l.day && abs($0.quantity - l.quantity) < 1e-9 } }
                if !fresh.isEmpty { extendLots[old.id, default: []].append(contentsOf: fresh) }
                r.extended.append(d.name)
                continue
            }
            let o = c.option
            let p = Position(name: d.name.isEmpty || d.name == d.identifier ? o.name : d.name, isin: d.isin ?? o.isin, wkn: d.wkn ?? o.wkn,
                             assetType: o.assetType == .other ? .stock : o.assetType, listing: o.listing(), lots: lots,
                             bankID: bankID, themeID: themeID, note: d.note)
            newPositions.append(p)
            r.added.append(p.name)
        }
        let finalBanks = banks, finalThemes = themes
        model.mutate { depot in
            depot.banks = finalBanks
            depot.themes = finalThemes
            depot.positions.append(contentsOf: newPositions)
            for (id, lots) in extendLots {
                if let i = depot.positions.firstIndex(where: { $0.id == id }) { depot.positions[i].lots.append(contentsOf: lots) }
            }
        }
        let ids = Set(newPositions.map(\.id)).union(extendLots.keys)
        if !ids.isEmpty { model.refresh(force: true, only: ids) }
        result = r
    }
}
