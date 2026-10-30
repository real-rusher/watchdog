import SwiftUI
import WatchdogCore

/// One value: price, verdict, chart with the 38 and 200 day lines, figures and purchases. Same content as on the Mac, read only.
struct PositionDetailView: View {
    @Environment(MobileModel.self) private var model
    let id: UUID
    @State private var range: ChartRange = .y1
    @AppStorage("chartInListingCurrency") private var chartLocal = false
    @State private var points: [Evaluator.ChartPoint] = []

    var body: some View {
        if let p = model.position(id) {
            let m = model.metrics(id)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(p, m)
                    if let f = model.freshness(p), f.isProblem || f.level == .noTradeToday { freshnessNotice(f) }
                    if let n = model.notice(p) { tickerNotice(n, p) }
                    if m?.quoteSuspect == true {
                        box(icon: "questionmark", caution: true, title: "Kurs unbestätigt",
                            text: model.snapshot?.status[p.listing.key]?.plausibilityNote ?? "Großer Kurssprung, den keine zweite Quelle bestätigt. Signale warten auf den Schlusskurs.")
                    }
                    verdict(m)
                    chart(p, m)
                    figures(p, m)
                    if !p.lots.isEmpty { lots(p) }
                }
                .padding(16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas)
            .navigationTitle(p.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bearbeiten") { model.editor = .edit(p.id) }
                }
            }
            .task(id: "\(id)|\(range.rawValue)|\(model.snapshot?.lastRefresh?.timeIntervalSince1970 ?? 0)") { await loadChart(p) }
        }
    }

    private func loadChart(_ p: Position) async {
        let rules = model.depot.rules
        let lines = rules.chartLines.contains(rules.ampel.line) ? rules.chartLines : rules.chartLines + [rules.ampel.line]
        points = await model.engine.chart(position: p, depot: model.depot, from: DayKey.today(in: .berlin).adding(days: -range.days), lines: lines)
    }

    private func header(_ p: Position, _ m: PositionMetrics?) -> some View {
        let ex = model.catalog[p.listing.exchangeID]
        return VStack(alignment: .leading, spacing: 8) {
            Text(p.name).type(22, .bold).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                tag(ex?.name ?? p.listing.exchangeID)
                Text(p.listing.ticker).type(13).foregroundStyle(Palette.inkSoft)
                if let isin = p.isin { Text(isin).type(13).foregroundStyle(Palette.inkSoft) }
                if p.isWatchOnly { tag("Beobachtung") }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(m?.priceEUR.map { Format.eur($0) } ?? "Kein Kurs").type(30, .bold).foregroundStyle(m?.priceEUR == nil ? Palette.inkSoft : Palette.ink)
                if let d = m?.dayChangePercent {
                    Text("\(Format.pct(d, signed: true)) heute").type(16, .semibold).foregroundStyle(Palette.change(d))
                }
            }
            if let m, let line = quoteLine(m) {
                Text(line).type(13).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quoteLine(_ m: PositionMetrics) -> String? {
        guard let t = m.quoteTime else { return nil }
        var parts = ["Kurs von \(Format.time(t))"]
        if let s = m.quoteSource { parts.append("Quelle \(s.displayName)") }
        if m.currency != "EUR", let pl = m.priceLocal { parts.append("an der Börse \(Format.money(pl, m.currency))") }
        return parts.joined(separator: ", ")
    }

    private func tag(_ s: String) -> some View {
        Text(s).type(12, .medium).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.rule))
    }

    private func box(icon: String, caution: Bool, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(caution ? Palette.caution : Palette.inkSoft).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).type(15, .semibold).foregroundStyle(Palette.ink)
                Text(text).type(13).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(caution ? Palette.cautionWash : Palette.zebra, in: RoundedRectangle(cornerRadius: 8))
    }

    private func freshnessNotice(_ f: Freshness) -> some View {
        var text = f.detail
        if let ls = f.lastSuccess { text += "\nLetzte erfolgreiche Abfrage \(Format.time(ls))." }
        let title = f.headline.prefix(1).uppercased() + f.headline.dropFirst()
        return box(icon: f.isProblem ? "exclamationmark.triangle.fill" : "clock", caution: f.isProblem, title: title, text: text)
    }

    private func tickerNotice(_ n: ListingNotice, _ p: Position) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            box(icon: n.needsUser ? "questionmark.circle.fill" : "checkmark.circle", caution: n.needsUser, title: n.headline, text: n.detail)
            if n.needsUser, n.symbol != nil, n.provider != nil {
                HStack(spacing: 18) {
                    Button("Ist dieselbe Firma") { model.confirmCompany(p, n) }.type(15, .semibold)
                    Button("Wert bearbeiten") { model.editor = .edit(p.id) }.type(15)
                }
                .padding(.leading, 12)
            }
        }
    }

    private func verdict(_ m: PositionMetrics?) -> some View {
        let v = Verdict.text(m, rules: model.depot.rules)
        let state = m?.ampel.state ?? .unknown
        return HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Palette.ampel(state)).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(v.title).type(17, .semibold).foregroundStyle(Palette.ink)
                Text(v.detail).type(14).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(m?.ampel.isFresh == true ? Palette.signalWash : Palette.zebra, in: RoundedRectangle(cornerRadius: 8))
    }

    private func chart(_ p: Position, _ m: PositionMetrics?) -> some View {
        let rules = model.depot.rules
        let lines = rules.chartLines.contains(rules.ampel.line) ? rules.chartLines : rules.chartLines + [rules.ampel.line]
        let cur = m?.currency ?? "EUR"
        let local = chartLocal && cur != "EUR"
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Zeitraum", selection: $range) {
                ForEach(ChartRange.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            if cur != "EUR" {
                Picker("Währung", selection: $chartLocal) {
                    Text("in Euro").tag(false)
                    Text("in \(Verdict.currencyName(cur))").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if points.count >= 2 {
                PriceChart(points: points, lines: lines, signalLine: rules.ampel.line,
                           averagePrice: p.isWatchOnly || local ? nil : p.averagePriceEUR, lots: p.lots, currency: cur, inLocal: local)
                    .frame(height: 280)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Palette.zebra)
                    .overlay(Text(model.isRefreshing ? "Kursverlauf wird geladen …" : "Kein Kursverlauf vorhanden").type(14).foregroundStyle(Palette.inkSoft))
                    .frame(height: 280)
            }
            HStack(spacing: 14) {
                legend(Palette.priceLine, "Kurs")
                ForEach(Array(lines.enumerated()), id: \.element) { i, s in legend(Palette.line(s, index: i), s.description) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text("Finger auf den Chart legen und ziehen zeigt den Kurs eines Tages.").type(12).foregroundStyle(Palette.inkFaint)
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 3)
            Text(s).type(12).foregroundStyle(Palette.inkSoft)
        }
    }

    private func figures(_ p: Position, _ m: PositionMetrics?) -> some View {
        let rules = model.depot.rules
        var items: [(String, String, Color)] = []
        if !p.isWatchOnly {
            items.append(("Stück", Format.qty(p.quantity), Palette.ink))
            items.append(("Wert", m?.valueEUR.map { Format.eur($0) } ?? Placeholder.missing, Palette.ink))
            items.append(("Ø Kaufkurs", p.averagePriceEUR.map { Format.eur($0) } ?? "unbekannt", Palette.ink))
            items.append(("Seit Kauf", m?.sincePurchasePercent.map { Format.pct($0, signed: true) + "  " + (m?.sincePurchaseEUR.map { Format.signedEUR($0) } ?? "") } ?? Placeholder.missing,
                          Palette.change(m?.sincePurchasePercent)))
        }
        items.append(("Seit 1.1.", m?.ytdPercent.map { Format.pct($0, signed: true) } ?? Placeholder.missing, Palette.change(m?.ytdPercent)))
        items.append(("30 Tage", m?.days30Percent.map { Format.pct($0, signed: true) } ?? Placeholder.missing, Palette.change(m?.days30Percent)))
        for spec in rules.chartLines + (rules.chartLines.contains(rules.ampel.line) ? [] : [rules.ampel.line]) {
            if let v = m?.lineValues[spec], let pl = m?.priceLocal, pl > 0, let pe = m?.priceEUR {
                items.append((spec.description, Format.eur(v * pe / pl), Palette.ink))
            }
        }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .topLeading)], alignment: .leading, spacing: 14) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).type(12).foregroundStyle(Palette.inkSoft)
                    Text(item.1).type(17, .semibold).foregroundStyle(item.2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func lots(_ p: Position) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Käufe").type(16, .semibold).foregroundStyle(Palette.ink)
            ForEach(p.lots.sorted { $0.day < $1.day }) { l in
                HStack {
                    Text(Format.day(l.day)).type(14).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(Format.qty(l.quantity)) Stück").type(14).foregroundStyle(Palette.inkSoft)
                    Text(l.hasCost ? Format.eur(l.totalCostEUR) : "Preis unbekannt").type(14, .medium).foregroundStyle(Palette.ink)
                        .frame(minWidth: 96, alignment: .trailing)
                }
                Rectangle().fill(Palette.rule).frame(height: 1)
            }
        }
    }
}
