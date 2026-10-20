import SwiftUI
import UniformTypeIdentifiers
import WatchdogCore

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uiScale) private var scale
    var session: ImportSession

    @State private var showFile = false
    @State private var dropTarget = false

    static let fileTypes: [UTType] = {
        var t: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .text, .spreadsheet, .data]
        for ext in ["xlsx", "xlsm", "ods", "xls", "numbers", "csv", "tsv", "txt"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let r = session.result {
                    ResultView(result: r) { dismiss() }
                } else if session.table == nil {
                    intro
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.result == nil {
                Divider()
                footer
            }
        }
        .frame(minWidth: 880, idealWidth: 1000, minHeight: 600, idealHeight: 740)
        .background(Palette.surface)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 10).stroke(Palette.signal, style: StrokeStyle(lineWidth: 3, dash: [8, 5])).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            session.load(url: u)
            return true
        } isTargeted: { dropTarget = $0 }
        .fileImporter(isPresented: $showFile, allowedContentTypes: Self.fileTypes) { result in
            if case .success(let url) = result { session.load(url: url) }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Text("Liste importieren").type(18, .semibold).foregroundStyle(Palette.ink)
            if let n = session.sourceName {
                Text(n).type(13).foregroundStyle(Palette.inkSoft).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Datei öffnen …") { showFile = true }
            Button("Aus Zwischenablage") {
                if let s = NSPasteboard.general.string(forType: .string) { session.load(text: s, name: "Zwischenablage") }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var intro: some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 14) {
            Text("Excel-Datei, CSV oder kopierte Tabelle").type(16, .semibold).foregroundStyle(Palette.ink)
            Text("Datei hierher ziehen oder über \u{201E}Datei öffnen\u{201C} wählen: Excel (.xlsx), LibreOffice (.ods), CSV und Text, auch Exporte von Banken. Aus Numbers oder Excel geht es auch per Kopieren und Einfügen. Watchdog erkennt die Spalten selbst; wichtig sind Name oder ISIN, dazu nach Wunsch Stück, Kaufkurs, Kaufdatum, Börse, Bank und Thema.")
                .type(14).foregroundStyle(Palette.inkSoft).frame(maxWidth: 680, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let e = session.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .type(13).foregroundStyle(Palette.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $session.text)
                .font(Typo.font(13, scale: scale))
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Palette.zebra, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if session.text.isEmpty {
                        Text("Tabelle hier einfügen oder Datei hierher ziehen …").type(13).foregroundStyle(Palette.inkFaint).padding(12).allowsHitTesting(false)
                    }
                }
            Button("Einlesen") { session.load(text: session.text, name: "Eingefügt") }
                .disabled(session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = session.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").type(13).foregroundStyle(Palette.down)
            }
            if let t = session.table {
                HStack(spacing: 12) {
                    Text("Spalten").type(14, .semibold).foregroundStyle(Palette.ink)
                    if session.sheets.count > 1 {
                        Picker("Blatt", selection: Binding(get: { session.sheetIndex }, set: { session.selectSheet($0) })) {
                            ForEach(Array(session.sheets.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                        }
                        .frame(width: 240)
                    }
                    Spacer()
                    Text(t.syntheticHeaders ? "ohne Kopfzeile erkannt" : "Zuordnung bei Bedarf ändern").type(12).foregroundStyle(Palette.inkFaint)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(t.headers.enumerated()), id: \.offset) { i, h in
                            ColumnPicker(title: h.isEmpty ? "Spalte \(i + 1)" : h, sample: t.samples(i, count: 1).first,
                                         field: i < session.mapping.count ? session.mapping[i] : .ignore) { f in
                                session.setField(f, column: i)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                HStack(spacing: 10) {
                    Text("Börse, wenn die Datei keine nennt:").type(13).foregroundStyle(Palette.inkSoft)
                    Picker("", selection: Binding(get: { session.defaultExchange }, set: { session.setDefaultExchange($0) })) {
                        ForEach(model.catalog.active) { e in Text(e.name).tag(e.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer()
                    Text(countText).type(12).foregroundStyle(Palette.inkSoft)
                }
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.drafts.enumerated()), id: \.element.id) { i, d in
                        DraftRow(session: session, draft: d, zebra: i % 2 == 1)
                    }
                    if session.drafts.isEmpty {
                        Text("Keine Wertpapiere erkannt. Bitte oben die Spalte mit Name oder ISIN zuordnen.")
                            .type(13).foregroundStyle(Palette.inkSoft).padding(24)
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 12)
    }

    private var countText: String {
        let n = session.drafts.count
        var s = n == 1 ? "1 Wert" : "\(n) Werte"
        let out = session.drafts.filter { !$0.include }.count
        if out > 0 { s += ", \(out) abgewählt" }
        return s
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if session.resolving {
                ProgressView(value: Double(session.resolvedCount), total: Double(max(1, session.drafts.count))).frame(width: 160)
                Text("Suche Handelsplätze \(session.resolvedCount) von \(session.drafts.count) …").type(12).foregroundStyle(Palette.inkSoft)
            } else if session.table != nil {
                let missing = session.drafts.filter { $0.include && session.states[$0.id]?.choice == nil }.count
                if missing > 0 {
                    Text(missing == 1 ? "1 Wert nicht gefunden" : "\(missing) Werte nicht gefunden").type(12, .medium).foregroundStyle(Palette.down)
                }
            }
            Spacer()
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            if session.table != nil {
                Button {
                    Task { await session.commit() }
                } label: {
                    Text(session.foundCount == 1 ? "1 Wert übernehmen" : "\(session.foundCount) Werte übernehmen")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.foundCount == 0 || session.committing)
            }
        }
        .padding(16)
    }
}

private struct ColumnPicker: View {
    var title: String
    var sample: String?
    var field: CSVImport.Field
    var set: (CSVImport.Field) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).type(12, .medium).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
            Picker("", selection: Binding(get: { field }, set: set)) {
                ForEach(CSVImport.Field.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            Text(sample ?? " ").type(11).foregroundStyle(Palette.inkFaint).lineLimit(1).truncationMode(.tail)
        }
        .frame(width: 168, alignment: .leading)
        .padding(8)
        .background(field == .ignore ? Color.clear : Palette.zebra, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DraftRow: View {
    @Environment(AppModel.self) private var model
    var session: ImportSession
    var draft: CSVImport.Draft
    var zebra: Bool

    var body: some View {
        let state = session.states[draft.id] ?? .waiting
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Toggle("", isOn: Binding(get: { draft.include }, set: { _ in session.toggle(draft.id) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                statusIcon(state)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name).type(14, .medium).foregroundStyle(draft.include ? Palette.ink : Palette.inkFaint).lineLimit(1)
                    Text([draft.isin, draft.wkn, draft.ticker].compactMap { $0 }.joined(separator: "  "))
                        .type(12).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                venue(state)
                    .frame(width: 230, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(draft.quantity.map { Format.qty($0) + " Stück" } ?? "beobachten").type(13).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(draft.totalCost.map { Format.money($0, draft.costCurrency) } ?? (draft.quantity == nil ? " " : "ohne Kaufpreis"))
                        .type(12).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                .frame(width: 120, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text([draft.bank, draft.theme].compactMap { $0 }.joined(separator: ", ")).type(12).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    Text(dates).type(12).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
            }
            let messages = draft.issues.map { ($0, true) } + notes(state).map { ($0, false) }
            if !messages.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                        Text(m.0).type(12).foregroundStyle(m.1 ? Palette.down : Palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 62)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(zebra ? Palette.zebra : Color.clear)
    }

    private var dates: String {
        let days = draft.lots.compactMap(\.day)
        guard let first = days.min() else { return draft.lots.isEmpty ? "" : "ohne Kaufdatum" }
        if draft.lots.count > 1 { return "\(draft.lots.count) Käufe ab \(Format.day(first))" }
        return "gekauft \(Format.day(first))"
    }

    private func notes(_ state: ImportSession.RowState) -> [String] {
        var n = draft.notes
        switch state {
        case .found(let c):
            if let note = c.note { n.append(note) }
            if session.existing(draft) != nil { n.append("schon im Depot, neue Käufe werden ergänzt") }
        case .notFound(let m): n.insert(m, at: 0)
        default: break
        }
        return n
    }

    @ViewBuilder
    private func statusIcon(_ s: ImportSession.RowState) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(Palette.inkFaint)
        case .searching: ProgressView().controlSize(.mini)
        case .found: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.up)
        case .notFound: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.down)
        }
    }

    @ViewBuilder
    private func venue(_ s: ImportSession.RowState) -> some View {
        switch s {
        case .found(let c):
            Menu {
                ForEach(c.alternatives) { o in
                    Button {
                        session.choose(o, for: draft.id)
                    } label: {
                        Text("\(o.exchangeLabel)  \(o.ticker)" + (o.currency.map { "  \($0)" } ?? ""))
                    }
                }
            } label: {
                Text("\(c.option.exchangeLabel) \u{00B7} \(c.option.ticker)").type(13)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("Handelsplatz wechseln")
        case .notFound:
            Text("nicht gefunden").type(13).foregroundStyle(Palette.down)
        default:
            Text(model.catalog[draft.exchangeID ?? session.defaultExchange]?.name ?? "").type(13).foregroundStyle(Palette.inkFaint)
        }
    }
}

private struct ResultView: View {
    var result: ImportSession.Result
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result.added.count == 1 ? "1 Wert übernommen" : "\(result.added.count) Werte übernommen").type(22, .semibold).foregroundStyle(Palette.ink)
            if !result.extended.isEmpty {
                Text("Bei \(result.extended.count) schon vorhandenen Werten wurden die Käufe ergänzt: \(result.extended.joined(separator: ", ")).")
                    .type(14).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            if !result.notFound.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nicht gefunden").type(15, .semibold).foregroundStyle(Palette.down)
                    Text(result.notFound.joined(separator: ", ")).type(14).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Text("Diese Werte bitte einzeln über \u{201E}Hinzufügen\u{201C} suchen, zum Beispiel mit ISIN oder WKN.")
                        .type(13).foregroundStyle(Palette.inkSoft)
                }
            }
            if !result.fxMissing.isEmpty {
                Text("Für \(Set(result.fxMissing).sorted().joined(separator: ", ")) fehlte ein Wechselkurs; der Kaufpreis bleibt leer und lässt sich in der Bearbeitung nachtragen.")
                    .type(13).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
            }
            Text("Die Kurse werden jetzt geladen.").type(13).foregroundStyle(Palette.inkSoft)
            Button("Fertig", action: done).keyboardShortcut(.defaultAction).controlSize(.large)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
