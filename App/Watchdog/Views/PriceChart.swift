import SwiftUI
import Charts
import WatchdogCore

enum ChartRange: String, CaseIterable, Identifiable {
    case m3 = "3M", m6 = "6M", y1 = "1J", y3 = "3J", y5 = "5J"
    var id: String { rawValue }
    var days: Int {
        switch self {
        case .m3: return 92
        case .m6: return 183
        case .y1: return 366
        case .y3: return 3 * 366
        case .y5: return 5 * 366
        }
    }
    var help: String {
        switch self {
        case .m3: return "3 Monate"
        case .m6: return "6 Monate"
        case .y1: return "1 Jahr"
        case .y3: return "3 Jahre"
        case .y5: return "5 Jahre"
        }
    }
}

struct PriceChart: View {
    var points: [Evaluator.ChartPoint]
    var lines: [LineSpec]
    var signalLine: LineSpec
    var averagePrice: Double?
    var lots: [Lot]
    var currency: String
    /// Show the original prices of the exchange instead of euro.
    var inLocal = false

    @State private var hoverIndex: Int?

    private struct Marker: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let up: Bool
    }

    var body: some View {
        let shown = thinned
        let crossings = crossingMarkers
        let lotMarks = lotMarkers
        Chart {
            ForEach(Array(lines.enumerated()), id: \.element) { idx, spec in
                ForEach(shown, id: \.day) { p in
                    if let v = line(p, spec) {
                        LineMark(x: .value("Tag", p.day.date), y: .value("Wert", v), series: .value("Linie", spec.description))
                            .foregroundStyle(Palette.line(spec, index: idx))
                            .lineStyle(StrokeStyle(lineWidth: spec == signalLine ? 2.4 : 1.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }
                }
            }
            ForEach(shown, id: \.day) { p in
                LineMark(x: .value("Tag", p.day.date), y: .value("Wert", price(p)), series: .value("Linie", "Kurs"))
                    .foregroundStyle(Palette.priceLine)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            if let avg = averagePrice, inRange(avg) {
                RuleMark(y: .value("Ø Kaufkurs", avg))
                    .foregroundStyle(Palette.inkSoft)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Ø Kaufkurs \(Format.eur(avg))").type(11).foregroundStyle(Palette.inkSoft)
                    }
            }
            ForEach(lotMarks) { m in
                PointMark(x: .value("Tag", m.date), y: .value("Wert", m.value))
                    .symbol(.diamond)
                    .symbolSize(46)
                    .foregroundStyle(Palette.ink)
            }
            ForEach(crossings) { m in
                PointMark(x: .value("Tag", m.date), y: .value("Wert", m.value))
                    .symbolSize(70)
                    .foregroundStyle(m.up ? Palette.up : Palette.down)
            }
            if let i = hoverIndex, i < points.count {
                let p = points[i]
                RuleMark(x: .value("Tag", p.day.date))
                    .foregroundStyle(Palette.inkFaint.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Tag", p.day.date), y: .value("Wert", price(p)))
                    .symbolSize(40)
                    .foregroundStyle(Palette.priceLine)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Palette.rule.opacity(0.6))
                AxisValueLabel(format: xFormat).font(Typo.font(11))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { v in
                AxisGridLine().foregroundStyle(Palette.rule.opacity(0.6))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(Format.number(d, decimals: abs(d) >= 1000 ? 0 : nil)).font(Typo.font(11)) }
                }
            }
        }
        .chartBackground { proxy in
            GeometryReader { geo in
                zones(proxy: proxy, geo: geo, shown: shown)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let frame = proxy.plotFrame else { return }
                            let x = loc.x - geo[frame].origin.x
                            if let date: Date = proxy.value(atX: x) { hoverIndex = nearest(date) }
                        case .ended:
                            hoverIndex = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let i = hoverIndex, i < points.count { HoverCard(point: points[i], lines: lines, currency: currency, inLocal: inLocal) }
        }
    }

    // MARK: Data helpers

    private func price(_ p: Evaluator.ChartPoint) -> Double { inLocal ? p.priceLocal : p.priceEUR }
    private func line(_ p: Evaluator.ChartPoint, _ spec: LineSpec) -> Double? { inLocal ? p.linesLocal[spec] : p.lines[spec] }

    /// Long ranges are thinned for drawing; crossings are computed on the full data.
    private var thinned: [Evaluator.ChartPoint] {
        guard points.count > 520 else { return points }
        let step = Int((Double(points.count) / 420).rounded(.up))
        var out = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if let last = points.last, out.last?.day != last.day { out.append(last) }
        return out
    }

    private var crossingMarkers: [Marker] {
        let prices = points.map { Optional(price($0)) }
        let signal = points.map { line($0, signalLine) }
        return Indicators.crossings(prices, signal).compactMap { c in
            guard let v = line(points[c.index], signalLine) else { return nil }
            return Marker(id: c.index, date: points[c.index].day.date, value: v, up: c.direction == .up)
        }
    }

    private var lotMarkers: [Marker] {
        guard let first = points.first?.day else { return [] }
        return lots.enumerated().compactMap { i, lot in
            guard lot.day >= first, let idx = points.lastIndex(where: { $0.day <= lot.day }) else { return nil }
            return Marker(id: i, date: points[idx].day.date, value: price(points[idx]), up: true)
        }
    }

    private var yDomain: ClosedRange<Double> {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for p in points {
            lo = min(lo, price(p)); hi = max(hi, price(p))
            for spec in lines { if let v = line(p, spec) { lo = min(lo, v); hi = max(hi, v) } }
        }
        if let a = averagePrice, a < hi * 1.6, a > lo * 0.6 { lo = min(lo, a); hi = max(hi, a) }
        guard lo.isFinite, hi.isFinite, hi > lo else { return 0...1 }
        let pad = (hi - lo) * 0.06
        return (lo - pad)...(hi + pad)
    }

    private func inRange(_ v: Double) -> Bool { yDomain.contains(v) }

    /// A little room on the right so the last axis label is not cut off.
    private var xDomain: ClosedRange<Date> {
        guard let a = points.first?.day.date, let b = points.last?.day.date, b > a else { return Date().addingTimeInterval(-86400)...Date() }
        return a...b.addingTimeInterval(b.timeIntervalSince(a) * 0.035)
    }

    private var xFormat: Date.FormatStyle {
        let span = points.count
        let de = Locale(identifier: "de_DE")
        return span > 400 ? Date.FormatStyle.dateTime.year().locale(de) : Date.FormatStyle.dateTime.month(.abbreviated).day().locale(de)
    }

    private func nearest(_ date: Date) -> Int? {
        guard !points.isEmpty else { return nil }
        let target = DayKey(date: date, timeZone: .utc)
        var best = 0
        var bestD = Int.max
        for (i, p) in points.enumerated() {
            let d = abs(p.day.days(to: target))
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// Green/red fill between price and the signal line.
    private func zones(proxy: ChartProxy, geo: GeometryProxy, shown: [Evaluator.ChartPoint]) -> some View {
        Canvas { ctx, _ in
            guard let frame = proxy.plotFrame else { return }
            let origin = geo[frame].origin
            func pt(_ d: DayKey, _ v: Double) -> CGPoint? {
                guard let x = proxy.position(forX: d.date), let y = proxy.position(forY: v) else { return nil }
                return CGPoint(x: x + origin.x, y: y + origin.y)
            }
            for i in 1..<max(1, shown.count) {
                let a = shown[i - 1], b = shown[i]
                guard let la = line(a, signalLine), let lb = line(b, signalLine),
                      let p1 = pt(a.day, price(a)), let p2 = pt(b.day, price(b)),
                      let q1 = pt(a.day, la), let q2 = pt(b.day, lb) else { continue }
                var path = Path()
                path.move(to: p1); path.addLine(to: p2); path.addLine(to: q2); path.addLine(to: q1); path.closeSubpath()
                let above = (price(a) + price(b)) >= (la + lb)
                ctx.fill(path, with: .color(above ? Palette.up.opacity(0.10) : Palette.down.opacity(0.13)))
            }
        }
    }
}

private struct HoverCard: View {
    var point: Evaluator.ChartPoint
    var lines: [LineSpec]
    var currency: String
    var inLocal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.day(point.day)).type(11, .semibold).foregroundStyle(Palette.inkSoft)
            Text(inLocal ? Format.money(point.priceLocal, currency) : Format.eur(point.priceEUR)).type(15, .semibold).foregroundStyle(Palette.ink)
            if currency != "EUR" {
                Text(inLocal ? Format.eur(point.priceEUR) : Format.money(point.priceLocal, currency)).type(11).foregroundStyle(Palette.inkSoft)
                Text("1 € = \(Format.number(1 / point.rate, decimals: 4)) \(CurrencyNormalizer.symbol(currency))").type(11).foregroundStyle(Palette.inkFaint)
            }
            ForEach(Array(lines.enumerated()), id: \.element) { i, spec in
                if let v = inLocal ? point.linesLocal[spec] : point.lines[spec] {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(Palette.line(spec, index: i)).frame(width: 10, height: 3)
                        Text("\(spec.shortLabel) \(inLocal ? Format.money(v, currency) : Format.eur(v))").type(11).foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .padding(8)
        .background(Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.rule))
        .padding(6)
        .allowsHitTesting(false)
    }
}
