import SwiftUI
import WatchdogCore

/// Depot totals on the left, the signal distribution on the right. Clicking a signal filters the table.
struct SummaryStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.totals
        VStack(spacing: 0) {
            if model.isExampleDepot {
                HStack(spacing: 12) {
                    Text("Das ist ein Beispieldepot mit echten Kursen.").type(13, .medium).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Button("Mit leerem Depot beginnen") { model.startEmpty() }
                        .buttonStyle(.borderless).type(13, .semibold)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 7)
                .background(Palette.signalWash)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) {
                    figures(t)
                    Spacer(minLength: 12)
                    SignalBar(totals: t)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 330)
                }
                VStack(alignment: .leading, spacing: 10) {
                    figures(t)
                    SignalBar(totals: t)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
        }
        .background(Palette.surface)
    }

    @ViewBuilder
    private func figures(_ t: Totals) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 26) {
            Figure(label: "Depotwert", value: t.holdings > 0 ? Format.eur(t.value, decimals: 0) : Placeholder.missing, color: Palette.ink, large: true)
            Figure(label: "Heute", value: t.holdings > 0 ? Format.signedEUR(t.dayChange) : Placeholder.missing,
                   sub: t.dayPercent.map { Format.pct($0, signed: true) }, color: Palette.change(t.dayChange))
            Figure(label: "Seit Kauf", value: t.holdings > 0 ? Format.signedEUR(t.sincePurchase) : Placeholder.missing,
                   sub: t.sincePurchasePercent.map { Format.pct($0, signed: true) }, color: Palette.change(t.sincePurchase))
        }
    }
}

private struct Figure: View {
    var label: String
    var value: String
    var sub: String? = nil
    var color: Color
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).type(12).foregroundStyle(Palette.inkSoft)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).type(large ? 24 : 18, .semibold).foregroundStyle(color)
                if let sub { Text(sub).type(13, .medium).foregroundStyle(color) }
            }
        }
        .fixedSize()
    }
}

/// Proportional bar: how many values are red, yellow, green. Each segment filters the table.
struct SignalBar: View {
    @Environment(AppModel.self) private var model
    var totals: Totals

    var body: some View {
        let order: [AmpelState] = [.red, .yellow, .green, .unknown]
        let total = max(1, order.reduce(0) { $0 + (totals.counts[$1] ?? 0) })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(order, id: \.self) { s in
                    let n = totals.counts[s] ?? 0
                    if n > 0 || s != .unknown {
                        Button {
                            model.filter = model.filter == .state(s) ? nil : .state(s)
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Palette.ampel(s)).frame(width: 9, height: 9)
                                Text("\(n)").type(15, .semibold).foregroundStyle(Palette.ink)
                                Text(shortLabel(s)).type(12).foregroundStyle(Palette.inkSoft)
                            }
                            .fixedSize()
                            .padding(.vertical, 2)
                            .padding(.horizontal, 5)
                            .background(model.filter == .state(s) ? Palette.signalWash : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(model.filter == .state(s) ? "Filter aufheben" : "Nur \(s.label.lowercased()) zeigen")
                    }
                }
                if totals.fresh > 0 {
                    Button {
                        model.filter = model.filter == .fresh ? nil : .fresh
                    } label: {
                        Text("\(totals.fresh) frisch gekreuzt")
                            .type(12, .semibold)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Palette.signal, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Werte, die die Linie in den letzten Handelstagen gekreuzt haben")
                }
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(order, id: \.self) { s in
                        let n = totals.counts[s] ?? 0
                        if n > 0 {
                            Rectangle().fill(Palette.ampel(s))
                                .frame(width: max(3, (g.size.width - 6) * CGFloat(n) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 5)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func shortLabel(_ s: AmpelState) -> String {
        switch s {
        case .red: return "unter"
        case .yellow: return "knapp"
        case .green: return "über"
        case .unknown: return "ohne Daten"
        }
    }
}
