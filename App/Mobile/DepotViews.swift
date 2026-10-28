import SwiftUI
import UniformTypeIdentifiers
import WatchdogCore

struct RootView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    /// iPad: list and detail side by side, also upright.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var m = model
        Group {
            if model.needsFolder {
                OnboardingView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    DepotListView()
                        .navigationTitle("Watchdog")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                                    .accessibilityLabel("Einstellungen")
                            }
                        }
                        .navigationSplitViewColumnWidth(min: 340, ideal: 560, max: 900)
                } detail: {
                    if let id = model.selection, model.position(id) != nil {
                        PositionDetailView(id: id)
                    } else {
                        Text("Wert auswählen").type(15).foregroundStyle(Palette.inkSoft)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Palette.canvas)
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .tint(Palette.ink)
            }
        }
        // Dots, gauges and spacing grow with the system text size; the text itself scales on its own.
        .environment(\.uiScale, Self.scale(typeSize))
        .sheet(isPresented: $m.showSettings) { MobileSettingsView() }
    }
}

extension RootView {
    static func scale(_ s: DynamicTypeSize) -> CGFloat {
        switch s {
        case .xSmall, .small, .medium, .large: return 1
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        case .accessibility1: return 1.5
        case .accessibility2: return 1.7
        default: return 1.9
        }
    }
}

/// First start: the iPhone needs the folder the Mac app writes in iCloud Drive.
struct OnboardingView: View {
    @Environment(MobileModel.self) private var model
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 44)).foregroundStyle(Palette.signal)
                Text("Watchdog auf dem iPhone").type(26, .bold).foregroundStyle(Palette.ink)
                Text("Das iPhone zeigt dasselbe Depot wie der Mac. Werte werden am Mac angelegt und bearbeitet; die Mac-App legt das Depot in iCloud Drive im Ordner \u{201E}Watchdog\u{201C} ab.")
                    .type(16).foregroundStyle(Palette.ink)
                Text("Bitte diesen Ordner einmal auswählen. Danach liest Watchdog ihn bei jedem Start von selbst.")
                    .type(16).foregroundStyle(Palette.inkSoft)
                Button {
                    picking = true
                } label: {
                    Text("Ordner \u{201E}Watchdog\u{201C} auswählen").type(17, .semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.signal, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Color.black.opacity(0.85))
                }
                if let e = model.depotError {
                    Text(e).type(14).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
                }
                Text("Mitteilungen: Der Mac meldet Durchbrüche zuerst. Prüft er 20 Minuten lang nicht, übernimmt das iPhone, danach die Apple Watch. Nichts wird doppelt gemeldet.")
                    .type(13).foregroundStyle(Palette.inkSoft).padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseFolder(url) }
        }
    }
}

// MARK: List

/// Fixed column widths for the wide layout (iPad, iPhone in landscape).
private enum Col {
    static let price: CGFloat = 92
    static let pct: CGFloat = 66
    static let value: CGFloat = 104
    static let gauge: CGFloat = 116
    static let wide: CGFloat = 600
}

struct DepotListView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List(selection: $m.selection) {
            SummaryHeader()
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Palette.canvas)
                .listRowSeparator(.hidden)
            Picker("Gruppierung", selection: $m.grouping) {
                ForEach(MobileModel.Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Palette.canvas)
            .listRowSeparator(.hidden)
            ColumnHeader()
                .listRowBackground(Palette.canvas)
                .listRowSeparator(.hidden)
            if model.depot.positions.isEmpty {
                Text(model.depotError ?? "Das Depot ist leer. Werte werden in der Mac-App angelegt.")
                    .type(15).foregroundStyle(Palette.inkSoft)
                    .listRowBackground(Palette.canvas)
            }
            ForEach(model.sections) { s in
                Section {
                    ForEach(s.positions) { p in
                        PositionRow(position: p)
                            .tag(p.id)
                            .listRowBackground(model.selection == p.id ? Palette.selection : Palette.surface)
                            .listRowSeparatorTint(Palette.rule)
                    }
                } header: {
                    HStack(spacing: 8) {
                        if let c = s.color { Circle().fill(c).frame(width: 9, height: 9) }
                        Text(s.title).type(15, .semibold).foregroundStyle(Palette.ink)
                        Text(s.positions.count == 1 ? "1 Wert" : "\(s.positions.count) Werte").type(12).foregroundStyle(Palette.inkSoft)
                        Spacer()
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .refreshable { await model.refresh(force: true) }
    }
}

struct SummaryHeader: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        let t = model.totals
        VStack(alignment: .leading, spacing: 12) {
            if !t.stale.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.caution)
                    Text(t.stale.count == 1 ? "1 Wert bekommt keine aktuellen Kurse: \(t.stale[0])."
                         : "\(t.stale.count) Werte bekommen keine aktuellen Kurse: \(t.stale.prefix(3).joined(separator: ", "))\(t.stale.count > 3 ? " und weitere" : "").")
                        .type(13).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.cautionWash, in: RoundedRectangle(cornerRadius: 8))
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 22) { figures(t) }
                VStack(alignment: .leading, spacing: 8) { figures(t) }
            }
            AmpelBar(counts: t.counts, fresh: t.fresh)
        }
    }

    @ViewBuilder
    private func figures(_ t: MobileModel.Totals) -> some View {
        if t.holdings > 0 {
            VStack(alignment: .leading, spacing: 1) {
                Text("Depotwert").type(12).foregroundStyle(Palette.inkSoft)
                Text(Format.eur(t.value, decimals: 0)).type(26, .bold).foregroundStyle(Palette.ink)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Heute").type(12).foregroundStyle(Palette.inkSoft)
                Text("\(Format.signedEUR(t.dayChange)) \(t.dayPercent.map { Format.pct($0, signed: true) } ?? "")")
                    .type(16, .semibold).foregroundStyle(Palette.change(t.dayChange))
            }
            if t.cost > 0 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Seit Kauf").type(12).foregroundStyle(Palette.inkSoft)
                    Text("\(Format.signedEUR(t.sincePurchase)) \(t.sincePurchasePercent.map { Format.pct($0, signed: true) } ?? "")")
                        .type(16, .semibold).foregroundStyle(Palette.change(t.sincePurchase))
                }
            }
        } else {
            Text("Nur beobachtete Werte").type(15, .medium).foregroundStyle(Palette.inkSoft)
        }
    }
}

/// Counts below, close to and above the line, with the bar the Mac shows.
struct AmpelBar: View {
    var counts: [AmpelState: Int]
    var fresh: Int

    var body: some View {
        let order: [AmpelState] = [.red, .yellow, .green, .unknown]
        let total = max(1, order.reduce(0) { $0 + (counts[$1] ?? 0) })
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { labels(order) }
                VStack(alignment: .leading, spacing: 4) { labels(order) }
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(order, id: \.self) { s in
                        if let n = counts[s], n > 0 {
                            Rectangle().fill(Palette.ampel(s)).frame(width: max(2, geo.size.width * CGFloat(n) / CGFloat(total) - 2))
                        }
                    }
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private func labels(_ order: [AmpelState]) -> some View {
        ForEach(order, id: \.self) { s in
            if let n = counts[s], n > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Palette.ampel(s)).frame(width: 9, height: 9)
                    Text("\(n)").type(15, .bold).foregroundStyle(Palette.ink)
                    Text(label(s)).type(13).foregroundStyle(Palette.inkSoft)
                }
            }
        }
        if fresh > 0 {
            Text("\(fresh) frisch gekreuzt").type(12, .semibold).foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Palette.signal, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func label(_ s: AmpelState) -> String {
        switch s {
        case .red: return "unter"
        case .yellow: return "knapp"
        case .green: return "über"
        case .unknown: return "ohne Daten"
        }
    }
}

/// Column titles for the wide layout; hidden where the rows use the compact layout.
struct ColumnHeader: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Text("Wertpapier").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                Text("Abstand 200er").frame(width: Col.gauge, alignment: .leading)
                Text("Kurs").frame(width: Col.price, alignment: .trailing)
                Text("Heute").frame(width: Col.pct, alignment: .trailing)
                Text("Wert").frame(width: Col.value, alignment: .trailing)
                Text("Seit Kauf").frame(width: Col.pct + 10, alignment: .trailing)
                Text("Seit 1.1.").frame(width: Col.pct, alignment: .trailing)
                Text("30 Tage").frame(width: Col.pct, alignment: .trailing)
            }
            .frame(minWidth: Col.wide)
            HStack {
                Text("Wertpapier")
                Spacer()
                Text("Kurs, heute, Abstand 200er")
            }
        }
        .type(12)
        .foregroundStyle(Palette.inkSoft)
        .lineLimit(1)
    }
}

struct PositionRow: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.uiScale) private var scale
    let position: Position

    var body: some View {
        let m = model.metrics(position.id)
        ViewThatFits(in: .horizontal) {
            wide(m)
            compact(m)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var stale: Bool { model.freshness(position)?.isProblem == true }

    private func nameBlock(_ m: PositionMetrics?) -> some View {
        HStack(spacing: 10) {
            AmpelDot(state: m?.ampel.state ?? .unknown, fresh: m?.ampel.isFresh == true, dimmed: stale)
            VStack(alignment: .leading, spacing: 2) {
                Text(position.name).type(15, .medium).foregroundStyle(Palette.ink).lineLimit(2)
                HStack(spacing: 6) {
                    Text(position.listing.ticker).type(12).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    Text(model.catalog[position.listing.exchangeID]?.badge ?? position.listing.exchangeID)
                        .type(11, .medium).foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, 4).padding(.vertical, 0.5)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.rule))
                        .fixedSize()
                    if let n = model.notice(position), n.needsUser {
                        Image(systemName: "questionmark.circle.fill").font(.caption2).foregroundStyle(Palette.caution)
                    } else if stale, let f = model.freshness(position) {
                        Text(f.headline).type(11, .semibold).foregroundStyle(Palette.caution).lineLimit(1)
                    } else if let c = m?.ampel.lastCrossing, m?.ampel.isFresh == true {
                        Text((c.direction == .down ? "\u{2193} " : "\u{2191} ") + Format.dayShort(c.day))
                            .type(11, .semibold).foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 4).background(Palette.signal, in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func priceBlock(_ m: PositionMetrics?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 2) {
                Text(m?.priceEUR.map { Format.eur($0) } ?? Placeholder.missing).type(15, .medium).foregroundStyle(Palette.ink)
                if m?.quoteSuspect == true { Text("?").type(13, .bold).foregroundStyle(Palette.caution) }
            }
            Text(m?.quoteTime.map { Format.time($0) } ?? " ").type(11).foregroundStyle(stale ? Palette.caution : Palette.inkFaint)
        }
        .lineLimit(1)
    }

    private func distanceText(_ m: PositionMetrics?) -> some View {
        Text(m?.ampel.distancePercent.map { Format.pct($0, signed: true) } ?? Placeholder.missing)
            .type(14, .semibold)
            .foregroundStyle(m.map { Palette.ampel($0.ampel.state) } ?? Palette.inkFaint)
            .opacity(stale ? 0.45 : 1)
    }

    private func pct(_ v: Double?, width: CGFloat) -> some View {
        Text(v.map { Format.pct($0, signed: true) } ?? Placeholder.missing).type(14, .medium)
            .foregroundStyle(Palette.change(v)).frame(width: width, alignment: .trailing)
    }

    /// iPad and landscape: the columns of the Mac table.
    private func wide(_ m: PositionMetrics?) -> some View {
        let watch = position.isWatchOnly
        return HStack(spacing: 0) {
            nameBlock(m).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                LineGauge(metrics: m, rules: model.depot.rules).frame(width: 52, height: 14).opacity(stale ? 0.4 : 1)
                distanceText(m)
            }
            .frame(width: Col.gauge, alignment: .leading)
            priceBlock(m, alignment: .trailing).frame(width: Col.price, alignment: .trailing)
            pct(m?.dayChangePercent, width: Col.pct)
            Text(watch ? "" : m?.valueEUR.map { Format.eur($0, decimals: $0 >= 10_000 ? 0 : 2) } ?? Placeholder.missing)
                .type(14, .medium).foregroundStyle(Palette.ink).frame(width: Col.value, alignment: .trailing)
            if watch { Text("").frame(width: Col.pct + 10) } else { pct(m?.sincePurchasePercent, width: Col.pct + 10) }
            pct(m?.ytdPercent, width: Col.pct)
            pct(m?.days30Percent, width: Col.pct)
        }
        .lineLimit(1)
        .frame(minWidth: Col.wide)
    }

    /// iPhone upright: name on the left, price and distance to the line on the right; stacked at very large text sizes.
    @ViewBuilder
    private func compact(_ m: PositionMetrics?) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                nameBlock(m)
                VStack(alignment: .leading, spacing: 4) {
                    priceBlock(m, alignment: .leading)
                    HStack(spacing: 6) {
                        Text("Abstand 200er").type(12).foregroundStyle(Palette.inkSoft)
                        distanceText(m)
                    }
                    pctLabel(m?.dayChangePercent)
                }
                .padding(.leading, 28 * scale)
            }
        } else {
            HStack(spacing: 8) {
                nameBlock(m)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    priceBlock(m, alignment: .trailing)
                    HStack(spacing: 8) {
                        pctLabel(m?.dayChangePercent)
                        distanceText(m)
                    }
                }
            }
        }
    }

    private func pctLabel(_ v: Double?) -> some View {
        Text(v.map { "heute " + Format.pct($0, signed: true) } ?? "").type(12).foregroundStyle(Palette.change(v)).lineLimit(1)
    }
}
