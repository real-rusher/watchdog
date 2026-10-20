import SwiftUI
import WatchdogCore

/// A security at one venue, merged from the search results of several providers.
struct LotDraft: Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var quantity = ""
    var price = ""
    var priceIsTotal = false

    var parsedQuantity: Double? { Lenient.germanDouble(quantity) }
    var parsedPrice: Double? { Lenient.germanDouble(price) }
    var total: Double? {
        guard let q = parsedQuantity, let p = parsedPrice else { return nil }
        return priceIsTotal ? p : p * q
    }
    var isEmpty: Bool { quantity.trimmingCharacters(in: .whitespaces).isEmpty && price.trimmingCharacters(in: .whitespaces).isEmpty }
    var isValid: Bool { (parsedQuantity ?? 0) > 0 && (parsedPrice ?? -1) >= 0 }
}

struct PositionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var request: EditorRequest

    @State private var searching = true
    @State private var query = ""
    @State private var results: [[ListingOption]] = []
    @State private var isLoading = false
    @State private var onlyActive = true

    @State private var name = ""
    @State private var isin = ""
    @State private var wkn = ""
    @State private var assetType: AssetType = .stock
    @State private var listing: Listing?
    @State private var bankID: UUID?
    @State private var themeID: UUID?
    @State private var lots: [LotDraft] = []
    @State private var note = ""
    @State private var newBank = ""
    @State private var newTheme = ""
    @State private var addingBank = false
    @State private var addingTheme = false
    @State private var forcedProvider: ProviderID?
    @State private var original: Position?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).type(18, .semibold).foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 10)
            Divider()
            if searching {
                searchPane
            } else {
                formPane
            }
            Divider()
            HStack {
                if !searching && listing != nil && original == nil {
                    Button("Andere Börse wählen") { query = isin.isEmpty ? name : isin; searching = true }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                if !searching {
                    Button(original == nil ? "Hinzufügen" : "Sichern") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 680)
        .background(Palette.surface)
        .onAppear(perform: load)
    }

    private var title: String {
        if original != nil { return searching ? "Börse ändern" : "Bearbeiten" }
        return searching ? "Wertpapier suchen" : "Wertpapier hinzufügen"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch request {
        case .add(let q):
            query = q ?? ""
            searching = true
        case .edit(let id):
            guard let p = model.position(id) else { return }
            original = p
            name = p.name
            isin = p.isin ?? ""
            wkn = p.wkn ?? ""
            assetType = p.assetType
            listing = p.listing
            bankID = p.bankID
            themeID = p.themeID
            note = p.note
            forcedProvider = p.listing.preferredProvider
            lots = p.lots.sorted { $0.day < $1.day }.map {
                LotDraft(id: $0.id, date: $0.day.date, quantity: Self.plain($0.quantity), price: Self.plain($0.totalCostEUR, decimals: 2), priceIsTotal: true)
            }
            searching = false
        }
    }

    // MARK: Search

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkSoft)
                TextField("ISIN, WKN, Name oder Kürzel", text: $query)
                    .textFieldStyle(.plain)
                    .type(17)
                    .onSubmit { Task { await runSearch(immediate: true) } }
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(Palette.zebra, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 22).padding(.top, 14)
            HStack {
                Toggle("Nur meine Börsen", isOn: $onlyActive).toggleStyle(.checkbox).type(13)
                Spacer()
                Text("Am sichersten mit der ISIN.").type(12).foregroundStyle(Palette.inkFaint)
            }
            .padding(.horizontal, 22)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, group in
                        let options = group.filter { o in !onlyActive || isActive(o) }
                        if !options.isEmpty, let first = group.first {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(first.name).type(15, .semibold).foregroundStyle(Palette.ink)
                                    if let i = first.isin { Text(i).type(12).foregroundStyle(Palette.inkSoft) }
                                    Text(first.assetType.label).type(12).foregroundStyle(Palette.inkFaint)
                                }
                                .padding(.bottom, 6)
                                ForEach(options) { o in
                                    OptionRow(option: o, catalog: model.catalog) { choose(o) }
                                }
                            }
                        }
                    }
                    if !isLoading && results.isEmpty && query.count >= 2 {
                        Text("Keine Treffer. Mit ISIN oder anderem Namen versuchen.").type(13).foregroundStyle(Palette.inkSoft)
                    }
                    if !isLoading && onlyActive && onlyInactiveHits {
                        Text("Treffer nur an Börsen, die nicht in deiner Liste sind. Haken bei \u{201E}Nur meine Börsen\u{201C} entfernen.").type(13).foregroundStyle(Palette.inkSoft)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
        }
        .task(id: query) { await runSearch(immediate: false) }
    }

    private func isActive(_ o: ListingOption) -> Bool {
        guard let id = o.exchangeID, let e = model.catalog[id] else { return false }
        return e.isActive
    }

    /// There are hits, but none at a venue in the user's list.
    private var onlyInactiveHits: Bool {
        let all = results.flatMap { $0 }
        return !all.isEmpty && !all.contains(where: isActive)
    }

    private func symbolSummary(_ l: Listing) -> String {
        let parts: [String] = l.symbols.keys.sorted().map { key in
            let name = ProviderID(rawValue: key)?.displayName ?? key
            let sym = l.symbols[key]?.split(separator: "|").first.map(String.init) ?? ""
            return "\(name) \(sym)"
        }
        return "Bekannte Kürzel: " + parts.joined(separator: ", ")
    }

    private func runSearch(immediate: Bool) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        if !immediate {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
        }
        isLoading = true
        let cands = await model.engine.search(q, depot: model.depot, keys: model.local.keys)
        if Task.isCancelled { return }
        results = ListingOption.build(cands, query: q, catalog: model.catalog)
        isLoading = false
    }

    private func choose(_ o: ListingOption) {
        guard o.exchangeID != nil else { return }
        listing = o.listing()
        if original == nil || name.isEmpty { name = o.name }
        if let i = o.isin { isin = i }
        if let w = o.wkn { wkn = w }
        assetType = o.assetType == .other ? .stock : o.assetType
        searching = false
        if original == nil && lots.isEmpty { lots = [LotDraft()] }
    }

    // MARK: Form

    private var formPane: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                HStack {
                    TextField("ISIN", text: $isin)
                    TextField("WKN", text: $wkn).frame(maxWidth: 140)
                }
                Picker("Art", selection: $assetType) {
                    ForEach(AssetType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if let l = listing {
                    LabeledContent("Börse") {
                        HStack {
                            Text((model.catalog[l.exchangeID]?.name ?? l.exchangeID) + ", Kürzel " + l.ticker)
                            Spacer()
                            Button("Ändern") { query = isin.isEmpty ? name : isin; searching = true }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section("Zuordnung") {
                Picker("Bank / Depot", selection: Binding(get: { addingBank ? UUID?.some(Self.newMarker) : bankID }, set: { v in
                    if v == Self.newMarker { addingBank = true } else { addingBank = false; bankID = v }
                })) {
                    Text("Keine Bank").tag(UUID?.none)
                    ForEach(model.depot.banks.sorted { $0.sortIndex < $1.sortIndex }) { b in Text(b.name).tag(UUID?.some(b.id)) }
                    Divider()
                    Text("Neue Bank …").tag(UUID?.some(Self.newMarker))
                }
                if addingBank {
                    HStack {
                        TextField("Name der Bank", text: $newBank)
                        Button("Anlegen") {
                            let n = newBank.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            bankID = model.addBank(n)
                            newBank = ""
                            addingBank = false
                        }
                    }
                }
                Picker("Thema", selection: Binding(get: { addingTheme ? UUID?.some(Self.newMarker) : themeID }, set: { v in
                    if v == Self.newMarker { addingTheme = true } else { addingTheme = false; themeID = v }
                })) {
                    Text("Kein Thema").tag(UUID?.none)
                    ForEach(model.depot.themes.sorted { $0.sortIndex < $1.sortIndex }) { t in Text(t.name).tag(UUID?.some(t.id)) }
                    Divider()
                    Text("Neues Thema …").tag(UUID?.some(Self.newMarker))
                }
                if addingTheme {
                    HStack {
                        TextField("Name des Themas, z. B. Uran", text: $newTheme)
                        Button("Anlegen") {
                            let n = newTheme.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            themeID = model.addTheme(n)
                            newTheme = ""
                            addingTheme = false
                        }
                    }
                }
            }
            Section {
                ForEach($lots) { $lot in
                    LotRow(lot: $lot) { lots.removeAll { $0.id == lot.id } }
                }
                Button {
                    lots.append(LotDraft())
                } label: {
                    Label("Kauf hinzufügen", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Käufe")
            } footer: {
                Text(lotsFooter).type(12).foregroundStyle(Palette.inkSoft)
            }
            Section("Notiz") {
                TextField("Optional", text: $note, axis: .vertical).lineLimit(2...5)
            }
            if let l = listing, let ex = model.catalog[l.exchangeID] {
                Section("Datenquelle für diesen Wert") {
                    Picker("Quelle", selection: $forcedProvider) {
                        Text("Automatisch (Reihenfolge aus den Einstellungen)").tag(ProviderID?.none)
                        ForEach(ProviderID.defaultOrder.filter { ex.supports($0) }) { p in Text(p.displayName).tag(ProviderID?.some(p)) }
                    }
                    Text(symbolSummary(l))
                        .type(12).foregroundStyle(Palette.inkSoft)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private static let newMarker = UUID(uuidString: "00000000-0000-0000-0000-00000000FFFF")!

    /// Number for editing: German decimal comma, no thousands grouping (so it parses back unambiguously).
    static func plain(_ v: Double, decimals: Int? = nil) -> String {
        if let d = decimals { return String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",") }
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.8f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    private var lotsFooter: String {
        let valid = lots.filter { !$0.isEmpty }
        if valid.isEmpty { return "Ohne Kauf wird der Wert nur beobachtet (Beobachtungsliste)." }
        let q = valid.compactMap(\.parsedQuantity).reduce(0, +)
        let t = valid.compactMap(\.total).reduce(0, +)
        guard q > 0 else { return "Stückzahl eintragen." }
        return "Zusammen \(Format.qty(q)) Stück für \(Format.eur(t)), Ø \(Format.eur(t / q)) pro Stück. Beträge in Euro."
    }

    private var canSave: Bool {
        guard listing != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return lots.filter { !$0.isEmpty }.allSatisfy(\.isValid)
    }

    private func save() {
        guard var l = listing else { return }
        l.preferredProvider = forcedProvider
        let cleanISIN = isin.trimmingCharacters(in: .whitespaces).uppercased()
        let newLots = lots.filter { !$0.isEmpty && $0.isValid }.map {
            Lot(id: $0.id, day: DayKey(date: $0.date, timeZone: .current), quantity: $0.parsedQuantity ?? 0, totalCostEUR: $0.total ?? 0)
        }
        var p = original ?? Position(name: name, listing: l)
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.isin = cleanISIN.isEmpty ? nil : cleanISIN
        p.wkn = wkn.trimmingCharacters(in: .whitespaces).isEmpty ? nil : wkn.trimmingCharacters(in: .whitespaces).uppercased()
        p.assetType = assetType
        p.listing = l
        p.lots = newLots
        p.bankID = bankID
        p.themeID = themeID
        p.note = note
        if original == nil { model.add(p) } else { model.update(p) }
        dismiss()
    }
}

private struct OptionRow: View {
    var option: ListingOption
    var catalog: ExchangeCatalog
    var choose: () -> Void
    @State private var hover = false

    var body: some View {
        let ex = option.exchangeID.flatMap { catalog[$0] }
        Button(action: choose) {
            HStack(spacing: 10) {
                Text(ex?.name ?? option.exchangeLabel).type(14, .medium).foregroundStyle(ex == nil ? Palette.inkFaint : Palette.ink)
                    .frame(width: 170, alignment: .leading)
                Text(option.ticker).type(13).foregroundStyle(Palette.inkSoft).frame(width: 90, alignment: .leading).lineLimit(1)
                Text(option.currency ?? ex?.currency ?? "").type(13).foregroundStyle(Palette.inkSoft).frame(width: 44, alignment: .leading)
                Text(option.lastPrice.map { Format.number($0) } ?? "").type(13).foregroundStyle(Palette.inkSoft).frame(width: 80, alignment: .trailing)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    ForEach(option.providers) { p in
                        Text(p.shortName).type(10, .semibold).foregroundStyle(Palette.inkSoft)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.rule))
                            .help(p.displayName)
                    }
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(hover && ex != nil ? Palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ex == nil)
        .onHover { hover = $0 }
        .help(ex == nil ? "Diese Börse ist nicht in der Liste. In den Einstellungen unter Börsen hinzufügen." : "Diesen Handelsplatz verwenden")
    }
}

private struct LotRow: View {
    @Binding var lot: LotDraft
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DatePicker("", selection: $lot.date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 110)
            TextField("Stück", text: $lot.quantity)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            TextField(lot.priceIsTotal ? "Gesamt €" : "€ pro Stück", text: $lot.price)
                .frame(width: 110)
                .multilineTextAlignment(.trailing)
            Picker("", selection: $lot.priceIsTotal) {
                Text("pro Stück").tag(false)
                Text("gesamt").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Kauf entfernen")
        }
    }
}
