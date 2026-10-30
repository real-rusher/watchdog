import SwiftUI
import WatchdogCore

/// Add a value (search, pick the venue, purchases) or edit one. Same fields and rules as the editor on the Mac.
struct MobileEditor: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: MobileModel.EditorTarget

    @State private var original: Position?
    @State private var listing: Listing?
    @State private var name = ""
    @State private var isin = ""
    @State private var wkn = ""
    @State private var assetType: AssetType = .stock
    @State private var bankID: UUID?
    @State private var themeID: UUID?
    @State private var note = ""
    @State private var lots: [LotDraft] = []
    @State private var choosingVenue = false
    @State private var confirmDelete = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if listing == nil || choosingVenue {
                    VenueSearch(initialQuery: searchQuery) { choose($0) }
                        .navigationTitle(original == nil ? "Wert hinzufügen" : "Börse wechseln")
                } else {
                    form
                        .navigationTitle(original == nil ? "Neuer Wert" : "Wert bearbeiten")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if choosingVenue && listing != nil { choosingVenue = false } else { dismiss() }
                    }
                }
                if listing != nil && !choosingVenue {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") { save() }.disabled(!canSave).fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var searchQuery: String {
        if let original { return original.isin ?? original.wkn ?? original.name }
        return ""
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard case .edit(let id) = target, let p = model.position(id) else { return }
        original = p
        listing = p.listing
        name = p.name
        isin = p.isin ?? ""
        wkn = p.wkn ?? ""
        assetType = p.assetType
        bankID = p.bankID
        themeID = p.themeID
        note = p.note
        lots = p.lots.sorted { $0.day < $1.day }.map(LotDraft.init)
    }

    private func choose(_ o: ListingOption) {
        guard o.exchangeID != nil else { return }
        listing = o.listing()
        if original == nil || name.isEmpty { name = o.name }
        if let i = o.isin { isin = i }
        if let w = o.wkn { wkn = w }
        assetType = o.assetType == .other ? .stock : o.assetType
        choosingVenue = false
        if original == nil && lots.isEmpty { lots = [LotDraft()] }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section("Wertpapier") {
                TextField("Name", text: $name)
                if let l = listing {
                    let ex = model.catalog[l.exchangeID]
                    LabeledContent("Börse") {
                        Text("\(ex?.name ?? l.exchangeID), \(l.ticker)").foregroundStyle(Palette.ink)
                    }
                    Button("Börse wechseln") { choosingVenue = true }
                }
                TextField("ISIN", text: $isin).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("WKN", text: $wkn).textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Section {
                ForEach($lots) { $lot in LotRow(lot: $lot) }
                    .onDelete { lots.remove(atOffsets: $0) }
                Button {
                    lots.append(LotDraft())
                } label: {
                    Label("Kauf hinzufügen", systemImage: "plus.circle")
                }
            } header: {
                Text("Käufe")
            } footer: {
                Text(lotsFooter)
            }
            Section("Gruppen") {
                Picker("Bank", selection: $bankID) {
                    Text("Ohne Bank").tag(UUID?.none)
                    ForEach(model.banks) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Picker("Thema", selection: $themeID) {
                    Text("Ohne Thema").tag(UUID?.none)
                    ForEach(model.themes) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            Section("Notiz") {
                TextField("Notiz", text: $note, axis: .vertical).lineLimit(2...6)
            }
            if let original {
                Section {
                    Button("Wert löschen", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Vor dem Löschen wird das Depot in iCloud Drive gesichert. Direkt danach lässt es sich rückgängig machen.")
                }
                .confirmationDialog("\u{201E}\(original.name)\u{201C} löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Löschen", role: .destructive) {
                        model.delete([original.id])
                        dismiss()
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var lotsFooter: String {
        let valid = lots.filter { !$0.isEmpty }
        if valid.isEmpty { return "Ohne Kauf wird der Wert nur beobachtet." }
        if !valid.allSatisfy(\.isValid) { return "Bitte bei jedem Kauf Stückzahl und Preis eintragen (Preis 0, wenn unbekannt)." }
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
        guard let l = listing else { return }
        let cleanISIN = isin.trimmingCharacters(in: .whitespaces).uppercased()
        let cleanWKN = wkn.trimmingCharacters(in: .whitespaces).uppercased()
        var p = original ?? Position(name: name, listing: l)
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.isin = cleanISIN.isEmpty ? nil : cleanISIN
        p.wkn = cleanWKN.isEmpty ? nil : cleanWKN
        p.assetType = assetType
        p.listing = l
        p.lots = lots.filter { !$0.isEmpty && $0.isValid }.map(\.lot)
        p.bankID = bankID
        p.themeID = themeID
        p.note = note
        if original == nil { model.add(p) } else { model.update(p) }
        dismiss()
    }
}

/// One purchase: date, quantity and price, the price per piece or in total.
private struct LotRow: View {
    @Binding var lot: LotDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Kaufdatum", selection: $lot.date, in: ...Date(), displayedComponents: .date)
            HStack {
                Text("Stück")
                TextField("0", text: $lot.quantity).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            HStack {
                Text(lot.priceIsTotal ? "Preis gesamt" : "Preis pro Stück")
                TextField("0,00", text: $lot.price).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                Text("€").foregroundStyle(Palette.inkSoft)
            }
            Picker("Preis", selection: $lot.priceIsTotal) {
                Text("pro Stück").tag(false)
                Text("gesamt").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }
}

/// Search by ISIN, WKN, name or ticker and pick the venue, like on the Mac.
struct VenueSearch: View {
    @Environment(MobileModel.self) private var model
    var initialQuery: String
    var choose: (ListingOption) -> Void

    @State private var query = ""
    @State private var results: [[ListingOption]] = []
    @State private var loading = false
    @State private var started = false

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkSoft)
                    TextField("ISIN, WKN, Name oder Kürzel", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    if loading { ProgressView() }
                }
            } footer: {
                if !loading && results.isEmpty && query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Text("Nichts gefunden. Am sichersten ist die ISIN.")
                }
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, group in
                Section(group.first.map { "\($0.name)\($0.isin.map { " · " + $0 } ?? "")" } ?? "") {
                    ForEach(group) { o in
                        let ex = o.exchangeID.flatMap { model.catalog[$0] }
                        Button {
                            choose(o)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ex?.name ?? o.exchangeLabel).foregroundStyle(ex == nil ? Palette.inkFaint : Palette.ink)
                                    Text("\(o.ticker) · \(o.currency ?? ex?.currency ?? "")").font(.footnote).foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                                if let p = o.lastPrice { Text(Format.number(p)).foregroundStyle(Palette.inkSoft) }
                            }
                        }
                        .disabled(ex == nil)
                    }
                }
            }
        }
        .onAppear {
            if !started { started = true; query = initialQuery }
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            loading = true
            let r = await model.search(query)
            if Task.isCancelled { return }
            results = r
            loading = false
        }
    }
}
