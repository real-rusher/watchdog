import SwiftUI
import WatchdogCore

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    var positionID: UUID
    var showsClose = false

    @State private var range: ChartRange = .y1
    @State private var points: [Evaluator.ChartPoint] = []
    @State private var confirmDelete = false
    /// Chart in the currency of the exchange instead of euro.
    @AppStorage("chartInListingCurrency") private var chartLocal = false

    var body: some View {
        if let p = model.position(positionID) {
            let m = model.metrics(positionID)
            let ex = model.catalog[p.listing.exchangeID]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(p, m, ex)
                    if let f = model.freshness(p), f.isProblem || f.level == .noTradeToday { dataNotice(f) }
                    if m?.quoteSuspect == true { suspectNotice(p) }
                    verdict(m)
                    chartBlock(p, m)
                    figures(p, m, ex)
                    if let hits = m?.hits, !hits.isEmpty { activeSignals(hits) }
                    if !p.lots.isEmpty { lotsBlock(p, m) }
                    dataBlock(p)
                }
                .padding(20)
            }
            .background(Palette.surface)
            .task(id: "\(positionID)|\(range.rawValue)|\(model.snapshot?.lastRefresh?.timeIntervalSince1970 ?? 0)|\(model.depot.rules.chartLines.count)") {
                await loadChart(p)
            }
            .confirmationDialog("\(p.name) löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) { model.delete(p.id) }
            } message: {
                Text("Die Position und alle erfassten Käufe werden entfernt.")
            }
        } else {
            Text("Nicht gefunden").type(14).foregroundStyle(Palette.inkSoft).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadChart(_ p: Position) async {
        let rules = model.depot.rules
        let from = DayKey.today(in: .berlin).adding(days: -range.days)
        points = await model.engine.chart(position: p, depot: model.depot, from: from, lines: rules.chartLines.contains(rules.ampel.line) ? rules.chartLines : rules.chartLines + [rules.ampel.line])
    }

    // MARK: Blocks

    private func header(_ p: Position, _ m: PositionMetrics?, _ ex: Exchange?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                AmpelDot(state: m?.ampel.state ?? .unknown, fresh: m?.ampel.isFresh == true, dimmed: model.freshness(p)?.isProblem == true)
                    .scaleEffect(1.35)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).type(24, .semibold).foregroundStyle(Palette.ink).lineLimit(2)
                    // Drops the ISIN before anything wraps when the panel is narrow.
                    ViewThatFits(in: .horizontal) {
                        tags(p, ex, isin: true)
                        tags(p, ex, isin: false)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button { model.editor = .edit(p.id) } label: { Image(systemName: "pencil") }
                        .help("Bearbeiten")
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help("Löschen")
                    if showsClose {
                        Button { model.selection = nil } label: { Image(systemName: "xmark") }
                            .keyboardShortcut(.cancelAction)
                            .help("Schließen")
                    } else {
                        Button { model.selection = nil } label: { Image(systemName: "sidebar.trailing") }
                            .help("Detailansicht schließen")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let pe = m?.priceEUR {
                    Text(Format.eur(pe)).type(30, .semibold).foregroundStyle(Palette.ink)
                } else {
                    Text(model.snapshot?.status[p.listing.key]?.isLoading == true ? "Kurs wird geladen" : "Kein Kurs")
                        .type(20, .medium).foregroundStyle(Palette.inkFaint)
                }
                if let d = m?.dayChangePercent {
                    Text(Format.pct(d, signed: true) + " heute").type(15, .medium).foregroundStyle(Palette.change(d))
                }
            }
            if let m, let t = m.quoteTime {
                Text(sourceLine(m, t, ex)).type(12).foregroundStyle(Palette.inkFaint)
            }
        }
    }

    private func tags(_ p: Position, _ ex: Exchange?, isin: Bool) -> some View {
        HStack(spacing: 8) {
            Tag(text: ex?.name ?? p.listing.exchangeID)
            Text(p.listing.ticker).type(12).foregroundStyle(Palette.inkSoft)
            if isin, let i = p.isin { Text(i).type(12).foregroundStyle(Palette.inkSoft).textSelection(.enabled) }
            if p.isWatchOnly { Tag(text: "Beobachtung") }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func sourceLine(_ m: PositionMetrics, _ t: Date, _ ex: Exchange?) -> String {
        var s = "Kurs von \(Format.time(t))"
        if let src = m.quoteSource { s += ", Quelle \(src.displayName)" }
        if let c = m.quoteConfirmedBy { s += ", bestätigt durch \(c.displayName)" }
        if m.currency != "EUR", let pl = m.priceLocal {
            s += ", an der Börse \(Format.money(pl, m.currency))"
            if let r = m.fxRateNow, r > 0 {
                let units = Format.number(1 / r, decimals: 4)
                if m.fxLive, let l = model.snapshot?.liveFX[m.currency] {
                    s += ", umgerechnet mit 1 € = \(units) \(CurrencyNormalizer.symbol(m.currency)) (Devisenkurs \(Format.time(l.time)))"
                } else {
                    s += ", umgerechnet mit 1 € = \(units) \(CurrencyNormalizer.symbol(m.currency)) (EZB-Referenzkurs)"
                }
            }
        }
        return s
    }

    /// Data has stopped or the market has not traded: say so above the verdict, because the verdict is then the last known state.
    private func dataNotice(_ f: Freshness) -> some View {
        let problem = f.isProblem
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: problem ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(problem ? Palette.caution : Palette.inkSoft)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.sentence(f.headline)).type(14, .semibold).foregroundStyle(Palette.ink)
                Text(f.detail).type(12).foregroundStyle(Palette.inkSoft).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let ls = f.lastSuccess {
                    Text("Letzte erfolgreiche Abfrage \(Format.time(ls)).").type(12).foregroundStyle(Palette.inkSoft)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(problem ? Palette.cautionWash : Palette.zebra, in: RoundedRectangle(cornerRadius: 6))
    }

    private func suspectNotice(_ p: Position) -> some View {
        let note = model.snapshot?.status[p.listing.key]?.plausibilityNote
            ?? "Großer Kurssprung, den keine zweite Quelle bestätigt. Signale warten auf den Schlusskurs."
        return HStack(alignment: .top, spacing: 10) {
            Text("?").type(16, .bold).foregroundStyle(Palette.caution)
            VStack(alignment: .leading, spacing: 3) {
                Text("Kurs unbestätigt").type(14, .semibold).foregroundStyle(Palette.ink)
                Text(note).type(12).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.cautionWash, in: RoundedRectangle(cornerRadius: 6))
    }

    static func sentence(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// One sentence that says what to do.
    private func verdict(_ m: PositionMetrics?) -> some View {
        let rules = model.depot.rules
        let lineName = rules.ampel.line.description
        let (title, detail): (String, String) = {
            guard let m, let d = m.ampel.distancePercent, let lv = m.lineValues[rules.ampel.line] else {
                return ("Noch keine Aussage möglich", "Für die \(lineName) werden mindestens \(rules.ampel.line.length) Handelstage Kursverlauf gebraucht.")
            }
            let lineEUR = (m.priceEUR ?? 0) / max(m.priceLocal ?? 1, 0.0000001) * lv
            let base = "\(Format.pct(abs(d))) \(d >= 0 ? "über" : "unter") der \(lineName) (\(Format.eur(lineEUR)))."
            var cross = ""
            if let c = m.ampel.lastCrossing {
                cross = " Zuletzt nach \(c.direction == .down ? "unten" : "oben") gekreuzt am \(Format.day(c.day))"
                cross += c.sessionsAgo == 0 ? ", heute." : c.sessionsAgo == 1 ? ", vor einem Handelstag." : ", vor \(c.sessionsAgo) Handelstagen."
            }
            switch m.ampel.state {
            case .red: return (m.ampel.isFresh ? "Gerade unter die Linie gefallen. Hinschauen." : "Unter der Linie. Hinschauen.", base + cross)
            case .yellow: return ("Knapp an der Linie. Beobachten.", base + cross)
            case .green: return (m.ampel.isFresh ? "Gerade über die Linie gestiegen." : "Über der Linie. Kein dringender Handlungsbedarf.", base + cross)
            case .unknown: return ("Noch keine Aussage möglich", base)
            }
        }()
        let state = m?.ampel.state ?? .unknown
        return HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Palette.ampel(state)).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).type(16, .semibold).foregroundStyle(Palette.ink)
                Text(detail).type(13).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(m?.ampel.isFresh == true ? Palette.signalWash : Palette.zebra, in: RoundedRectangle(cornerRadius: 6))
    }

    private func chartBlock(_ p: Position, _ m: PositionMetrics?) -> some View {
        let rules = model.depot.rules
        let lines = rules.chartLines.contains(rules.ampel.line) ? rules.chartLines : rules.chartLines + [rules.ampel.line]
        let cur = m?.currency ?? "EUR"
        let local = chartLocal && cur != "EUR"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Zeitraum", selection: $range) {
                    ForEach(ChartRange.allCases) { r in Text(r.rawValue).tag(r).help(r.help) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                if cur != "EUR" {
                    Picker("Währung", selection: $chartLocal) {
                        Text("in Euro").tag(false)
                        Text("in \(Self.currencyName(cur))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Chart in Euro oder in der Währung der Börse zeigen")
                } else {
                    Text("in Euro").type(12).foregroundStyle(Palette.inkFaint)
                }
            }
            if points.count >= 2 {
                PriceChart(points: points, lines: lines, signalLine: rules.ampel.line,
                           averagePrice: p.isWatchOnly || local ? nil : p.averagePriceEUR, lots: p.lots, currency: cur, inLocal: local)
                    .frame(height: 300 * min(scale, 1.2))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Palette.zebra)
                    .overlay(Text(model.snapshot?.status[p.listing.key]?.isLoading == true ? "Kursverlauf wird geladen …" : "Kein Kursverlauf vorhanden")
                        .type(13).foregroundStyle(Palette.inkSoft))
                    .frame(height: 300 * min(scale, 1.2))
            }
            HStack(spacing: 16) {
                LegendItem(color: Palette.priceLine, label: "Kurs", width: 1.6)
                ForEach(Array(lines.enumerated()), id: \.element) { i, s in
                    LegendItem(color: Palette.line(s, index: i), label: s.description, width: s == rules.ampel.line ? 2.4 : 1.5)
                }
                if !p.isWatchOnly && !local { LegendItem(color: Palette.inkSoft, label: "Ø Kaufkurs", width: 1, dashed: true) }
            }
            if cur != "EUR" {
                Text(chartNote(cur, local: local, exchange: model.catalog[p.listing.exchangeID]))
                    .type(11).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func currencyName(_ c: String) -> String {
        switch c {
        case "USD": return "US-Dollar"
        case "JPY": return "Yen"
        case "GBP": return "Pfund"
        case "CHF": return "Franken"
        case "CAD": return "kanad. Dollar"
        case "AUD": return "austral. Dollar"
        case "NOK": return "norw. Kronen"
        case "SEK": return "schwed. Kronen"
        case "DKK": return "dän. Kronen"
        default: return c
        }
    }

    private func chartNote(_ cur: String, local: Bool, exchange: Exchange?) -> String {
        let place = exchange.map { " an der Börse \($0.name)" } ?? ""
        if local {
            return "Originalkurse in \(Self.currencyName(cur))\(place), genau wie dort gehandelt. Der Kaufkurs ist in Euro erfasst und hier deshalb ausgeblendet."
        }
        var s = "Jeder Tag ist mit dem EZB-Referenzkurs genau dieses Tages in Euro umgerechnet"
        if let l = model.snapshot?.liveFX[cur] {
            s += ", der heutige Kurs mit dem aktuellen Devisenkurs (1 € = \(Format.number(l.unitsPerEUR, decimals: 4)) \(CurrencyNormalizer.symbol(cur)), \(Format.time(l.time)))"
        }
        s += ". Die Linien werden in \(Self.currencyName(cur)) berechnet und ebenso umgerechnet, damit Durchbrüche genau dort liegen, wo sie\(place) passieren."
        return s
    }

    private func figures(_ p: Position, _ m: PositionMetrics?, _ ex: Exchange?) -> some View {
        let rules = model.depot.rules
        var items: [(String, String, Color)] = []
        let toEUR = (m?.priceEUR ?? 0) / max(m?.priceLocal ?? 1, 0.0000001)
        if !p.isWatchOnly {
            items.append(("Stück", Format.qty(p.quantity), Palette.ink))
            items.append(("Ø Kaufkurs", p.averagePriceEUR.map { Format.eur($0) } ?? Placeholder.missing, Palette.ink))
            items.append(("Wert", m?.valueEUR.map { Format.eur($0) } ?? Placeholder.missing, Palette.ink))
            items.append(("Seit Kauf", m?.sincePurchasePercent.map { Format.pct($0, signed: true) + "  " + Format.signedEUR(m?.sincePurchaseEUR ?? 0) } ?? Placeholder.missing,
                          Palette.change(m?.sincePurchasePercent)))
        }
        items.append(("Seit 1.1.", m?.ytdPercent.map { Format.pct($0, signed: true) } ?? Placeholder.missing, Palette.change(m?.ytdPercent)))
        items.append(("30 Tage", m?.days30Percent.map { Format.pct($0, signed: true) } ?? Placeholder.missing, Palette.change(m?.days30Percent)))
        for spec in rules.chartLines.sorted(by: { $0.length < $1.length }) {
            if let v = m?.lineValues[spec] {
                var text = Format.eur(v * toEUR)
                if let m, m.currency != "EUR" { text += "  (\(Format.money(v, m.currency)))" }
                items.append((spec.description, text, Palette.ink))
            }
        }
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(0..<((items.count + 1) / 2), id: \.self) { r in
                GridRow {
                    ForEach(0..<2, id: \.self) { c in
                        let i = r * 2 + c
                        if i < items.count {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(items[i].0).type(12).foregroundStyle(Palette.inkSoft)
                                Text(items[i].1).type(15, .medium).foregroundStyle(items[i].2).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func activeSignals(_ hits: [RuleHit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aktive Signale").type(15, .semibold).foregroundStyle(Palette.ink)
            ForEach(hits, id: \.dedupKey) { h in
                HStack(spacing: 8) {
                    Circle().fill(h.rule.severity == .alarm ? Palette.down : h.rule.severity == .warning ? Palette.caution : Palette.up).frame(width: 8, height: 8)
                    Text(h.rule.name).type(13).foregroundStyle(Palette.ink)
                    if let d = h.eventDay { Text("am \(Format.day(d))").type(12).foregroundStyle(Palette.inkSoft) }
                }
            }
        }
    }

    private func lotsBlock(_ p: Position, _ m: PositionMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.lots.count == 1 ? "Kauf" : "Käufe").type(15, .semibold).foregroundStyle(Palette.ink)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Datum").gridColumnAlignment(.leading)
                    Text("Stück")
                    Text("Preis/Stück")
                    Text("Gesamt")
                    Text("Ergebnis")
                }
                .type(11).foregroundStyle(Palette.inkSoft)
                ForEach(p.lots.sorted { $0.day < $1.day }) { lot in
                    let now = m?.priceEUR.map { $0 * lot.quantity }
                    let res = lot.hasCost ? now.map { $0 - lot.totalCostEUR } : nil
                    GridRow {
                        Text(Format.day(lot.day)).gridColumnAlignment(.leading)
                        Text(Format.qty(lot.quantity))
                        Text(lot.hasCost ? Format.eur(lot.pricePerUnitEUR) : "ohne Preis")
                        Text(lot.hasCost ? Format.eur(lot.totalCostEUR) : Placeholder.missing)
                        Text(res.map { Format.signedEUR($0) } ?? Placeholder.missing).foregroundStyle(Palette.change(res))
                    }
                    .type(13).foregroundStyle(Palette.ink)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    private func dataBlock(_ p: Position) -> some View {
        let st = model.snapshot?.status[p.listing.key]
        let m = model.metrics(p.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Daten").type(15, .semibold).foregroundStyle(Palette.ink)
            Text(dataSummary(st, m)).type(12).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            if let note = st?.plausibilityNote, m?.quoteSuspect != true {
                Text(note).type(12).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            if let e = st?.lastError {
                Text(e).type(12).foregroundStyle(Palette.down).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !p.note.isEmpty {
                Text(p.note).type(13).foregroundStyle(Palette.ink).padding(.top, 4)
            }
            Button("Daten neu laden") { model.reloadData(for: p.id) }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    private func dataSummary(_ st: ListingStatus?, _ m: PositionMetrics?) -> String {
        var parts: [String] = []
        if let q = st?.quoteSource { parts.append("Kurs über \(q.displayName)") }
        if let h = st?.historySource { parts.append("Verlauf über \(h.displayName)") }
        if let n = m?.historyCount, n > 0 { parts.append("\(n) Handelstage gespeichert") }
        if let d = m?.lastBarDay { parts.append("letzter Schlusskurs \(Format.day(d))") }
        if let t = st?.lastQuoteSuccess { parts.append("zuletzt erfolgreich abgefragt \(Format.time(t))") }
        if let n = st?.quoteFailures, n > 0 { parts.append(n == 1 ? "1 Fehlversuch seitdem" : "\(n) Fehlversuche seitdem") }
        return parts.isEmpty ? "Noch keine Daten geladen." : parts.joined(separator: ", ") + "."
    }
}

struct Tag: View {
    var text: String
    var body: some View {
        Text(text).type(11, .medium).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.rule))
    }
}

struct LegendItem: View {
    var color: Color
    var label: String
    var width: CGFloat
    var dashed = false
    var body: some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: CGPoint(x: 0, y: 2)); p.addLine(to: CGPoint(x: 16, y: 2)) }
                .stroke(color, style: StrokeStyle(lineWidth: width, dash: dashed ? [3, 2] : []))
                .frame(width: 16, height: 4)
            Text(label).type(12).foregroundStyle(Palette.inkSoft)
        }
    }
}
