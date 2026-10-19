import SwiftUI
import UniformTypeIdentifiers
import WatchdogCore

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var table: CSVImport.Table?
    @State private var mapping: [CSVImport.Field] = []
    @State private var drafts: [CSVImport.Draft] = []
    @State private var resolved: [UUID: ListingOption] = [:]
    @State private var problems: [UUID: String] = [:]
    @State private var defaultExchange = "TGAT"
    @State private var resolving = false
    @State private var resolvedCount = 0
    @State private var showFile = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Liste importieren").type(18, .semibold).foregroundStyle(Palette.ink)
                Spacer()
                Button("Datei öffnen …") { showFile = true }
                Button("Aus Zwischenablage") { paste() }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
            if table == nil {
                intro
            } else {
                content
            }
            Divider()
            HStack {
                if resolving {
                    ProgressView(value: Double(resolvedCount), total: Double(max(1, drafts.count))).frame(width: 160)
                    Text("Handelsplätze werden gesucht …").type(12).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                if table != nil {
                    Button("Handelsplätze suchen") { Task { await resolveAll() } }
                        .disabled(resolving || drafts.isEmpty)
                    Button("\(readyCount) Werte übernehmen") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(readyCount == 0 || resolving)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 600, idealHeight: 720)
        .background(Palette.surface)
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]) { result in
            if case .success(let url) = result { openFile(url) }
        }
        .onAppear {
            defaultExchange = model.local.defaultImportExchange
            if let t = model.importPrefill {
                model.importPrefill = nil
                text = t
                parse(t)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("So geht es am schnellsten").type(16, .semibold).foregroundStyle(Palette.ink)
            Text("Eine CSV-Datei öffnen (zum Beispiel den Export eines Musterdepots) oder in Excel/Numbers die Tabelle markieren, kopieren und hier einfügen. Die erste Zeile sollte Spaltennamen enthalten, etwa Name, ISIN, Stück, Kaufkurs, Kaufdatum, Börse, Bank und Thema.")
                .type(14).foregroundStyle(Palette.inkSoft).frame(maxWidth: 640, alignment: .leading)
            TextEditor(text: $text)
                .font(Typo.font(13))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .background(Palette.zebra, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Hier einfügen …").type(13).foregroundStyle(Palette.inkFaint).padding(8).allowsHitTesting(false)
                    }
                }
            Button("Einlesen") { parse(text) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = table {
                Text("Spalten zuordnen").type(14, .semibold).foregroundStyle(Palette.ink)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(t.headers.enumerated()), id: \.offset) { i, h in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(h.isEmpty ? "Spalte \(i + 1)" : h).type(12, .medium).foregroundStyle(Palette.inkSoft).lineLimit(1)
                                Picker("", selection: Binding(get: { i < mapping.count ? mapping[i] : .ignore }, set: { v in
                                    if i < mapping.count { mapping[i] = v; rebuild() }
                                })) {
                                    ForEach(CSVImport.Field.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 170)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                HStack(spacing: 10) {
                    Text("Börse für Zeilen ohne Börse:").type(13).foregroundStyle(Palette.inkSoft)
                    Picker("", selection: $defaultExchange) {
                        ForEach(model.catalog.active) { e in Text(e.name).tag(e.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: defaultExchange) { _, v in model.updateLocal { $0.defaultImportExchange = v } }
                    Spacer()
                    Text("\(drafts.count) Zeilen erkannt").type(12).foregroundStyle(Palette.inkFaint)
                }
            }
            List {
                ForEach(drafts) { d in
                    DraftRow(draft: d, option: resolved[d.id], problem: problems[d.id], catalog: model.catalog, fallbackExchange: defaultExchange)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var readyCount: Int { drafts.filter { resolved[$0.id] != nil }.count }

    // MARK: Input

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            text = s
            parse(s)
        }
    }

    private func openFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        text = s
        parse(s)
    }

    private func parse(_ s: String) {
        let t = CSVImport.parse(s)
        table = t
        mapping = CSVImport.guessMapping(t.headers)
        rebuild()
    }

    private func rebuild() {
        guard let t = table else { return }
        drafts = CSVImport.drafts(t, mapping: mapping, catalog: model.catalog)
        resolved = [:]
        problems = [:]
    }

    // MARK: Resolve

    private func resolveAll() async {
        resolving = true
        resolvedCount = 0
        let list = drafts
        for d in list {
            let target = d.exchangeID ?? defaultExchange
            let queries = [d.isin, d.wkn, d.ticker, d.name].compactMap { $0 }.filter { !$0.isEmpty }
            var found: ListingOption?
            var seen: Set<String> = []
            for q in queries {
                let cands = await model.engine.search(q, depot: model.depot, keys: model.local.keys)
                let groups = ListingOption.build(cands, query: q, catalog: model.catalog)
                let options = groups.flatMap { $0 }
                for o in options { if let e = o.exchangeID, let n = model.catalog[e]?.name { seen.insert(n) } }
                let match = options.first { o in
                    o.exchangeID == target && (d.isin == nil || o.isin == nil || o.isin == d.isin)
                }
                if let m = match { found = m; break }
            }
            if let f = found {
                resolved[d.id] = f
                problems[d.id] = nil
            } else {
                let name = model.catalog[target]?.name ?? target
                problems[d.id] = seen.isEmpty ? "Nicht gefunden" : "An \(name) nicht gefunden. Vorhanden: " + seen.sorted().prefix(5).joined(separator: ", ")
            }
            resolvedCount += 1
        }
        resolving = false
    }

    private func commit() {
        var created = 0
        for d in drafts {
            guard let o = resolved[d.id] else { continue }
            var bankID: UUID?
            if let b = d.bank?.trimmingCharacters(in: .whitespaces), !b.isEmpty {
                bankID = model.depot.banks.first { $0.name.caseInsensitiveCompare(b) == .orderedSame }?.id ?? model.addBank(b)
            }
            var themeID: UUID?
            if let t = d.theme?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
                themeID = model.depot.themes.first { $0.name.caseInsensitiveCompare(t) == .orderedSame }?.id ?? model.addTheme(t)
            }
            var lots: [Lot] = []
            if let q = d.quantity, q > 0 {
                lots.append(Lot(day: d.day ?? DayKey.today(), quantity: q, totalCostEUR: d.totalCostEUR ?? 0))
            }
            let p = Position(name: d.name.isEmpty ? o.name : d.name, isin: d.isin ?? o.isin, wkn: d.wkn ?? o.wkn,
                             assetType: o.assetType == .other ? .stock : o.assetType, listing: o.listing(), lots: lots,
                             bankID: bankID, themeID: themeID, note: d.note)
            model.mutate { $0.positions.append(p) }
            created += 1
        }
        model.notice = "\(created) Werte übernommen. Kurse werden geladen."
        model.refresh(force: true)
        dismiss()
    }
}

private struct DraftRow: View {
    var draft: CSVImport.Draft
    var option: ListingOption?
    var problem: String?
    var catalog: ExchangeCatalog
    var fallbackExchange: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: option != nil ? "checkmark.circle.fill" : problem != nil ? "xmark.circle" : "circle")
                .foregroundStyle(option != nil ? Palette.up : problem != nil ? Palette.down : Palette.inkFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.name).type(14, .medium).foregroundStyle(Palette.ink)
                Text([draft.isin, draft.wkn, draft.ticker].compactMap { $0 }.joined(separator: "  ")).type(12).foregroundStyle(Palette.inkSoft)
            }
            .frame(width: 260, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog[draft.exchangeID ?? fallbackExchange]?.name ?? (draft.exchangeText ?? "")).type(13).foregroundStyle(Palette.ink)
                if let o = option { Text("Kürzel \(o.ticker)").type(12).foregroundStyle(Palette.inkSoft) }
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(draft.quantity.map { Format.qty($0) + " Stück" } ?? "beobachten").type(13).foregroundStyle(Palette.ink)
                if let t = draft.totalCostEUR { Text(Format.eur(t)).type(12).foregroundStyle(Palette.inkSoft) }
            }
            .frame(width: 110, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text([draft.bank, draft.theme].compactMap { $0 }.joined(separator: ", ")).type(12).foregroundStyle(Palette.inkSoft)
                if let d = draft.day { Text("gekauft \(Format.day(d))").type(12).foregroundStyle(Palette.inkSoft) }
                ForEach(draft.issues + (problem.map { [$0] } ?? []), id: \.self) { i in
                    Text(i).type(12).foregroundStyle(Palette.down)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
