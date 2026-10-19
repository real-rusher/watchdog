import SwiftUI
import WatchdogCore

enum Column: String, CaseIterable, Identifiable {
    case name, gauge, price, day, quantity, avgPrice, value, sincePurchase, ytd, days30

    var id: String { rawValue }

    func title(_ rules: RuleSet) -> String {
        switch self {
        case .name: return "Wertpapier"
        case .gauge: return "Abstand \(rules.ampel.line.shortLabel)"
        case .price: return "Kurs"
        case .day: return "Heute"
        case .quantity: return "Stück"
        case .avgPrice: return "Ø Kaufkurs"
        case .value: return "Wert"
        case .sincePurchase: return "Seit Kauf"
        case .ytd: return "Seit 1.1."
        case .days30: return "30 Tage"
        }
    }

    /// Width at font scale 1; `name` is flexible and uses this as minimum.
    var width: CGFloat {
        switch self {
        case .name: return 190
        case .gauge: return 150
        case .price: return 106
        case .day: return 72
        case .quantity: return 74
        case .avgPrice: return 92
        case .value: return 108
        case .sincePurchase: return 110
        case .ytd: return 74
        case .days30: return 74
        }
    }

    /// Lower numbers stay visible longer when the window gets narrow.
    var priority: Int {
        switch self {
        case .name, .gauge: return 0
        case .price, .day: return 1
        case .value, .sincePurchase: return 2
        case .days30, .ytd: return 3
        case .quantity: return 4
        case .avgPrice: return 5
        }
    }

    var sortKey: SortKey? {
        switch self {
        case .name: return .name
        case .gauge: return .signal
        case .day: return .day
        case .value: return .value
        case .sincePurchase: return .sincePurchase
        case .ytd: return .ytd
        case .days30: return .days30
        default: return nil
        }
    }

    var trailing: Bool { self != .name && self != .gauge }

    static func visible(width: CGFloat, scale: CGFloat, hidden: Set<String>) -> [Column] {
        var cols = Column.allCases.filter { !hidden.contains($0.rawValue) || $0 == .name || $0 == .gauge }
        func need(_ c: [Column]) -> CGFloat { c.reduce(0) { $0 + $1.width * scale } + Metrics.gutter * 2 }
        while need(cols) > width, let drop = cols.filter({ $0.priority > 0 }).max(by: { $0.priority < $1.priority }) {
            cols.removeAll { $0 == drop }
        }
        return cols
    }
}

struct QuoteTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    var availableWidth: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let cols = Column.visible(width: availableWidth, scale: scale, hidden: model.local.hiddenColumns)
        let layoutKey = cols.map(\.rawValue).joined(separator: ",") + "|\(scale)"
        let sections = model.sections
        VStack(spacing: 0) {
            HeaderRow(columns: cols)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { s in
                            Section {
                                if !model.local.collapsedSections.contains(s.id) {
                                    ForEach(Array(s.rows.enumerated()), id: \.element.id) { i, r in
                                        // The id includes the column layout so rows are rebuilt when columns appear or disappear.
                                        QuoteRow(row: r, columns: cols, zebra: i % 2 == 1)
                                            .id(Self.rowID(r.id, layoutKey))
                                    }
                                }
                            } header: {
                                SectionHeaderRow(section: s, columns: cols)
                                    .id(layoutKey + s.id)
                            }
                        }
                        if sections.isEmpty {
                            Text(model.filter != nil || !model.searchText.isEmpty ? "Keine Werte passen zum Filter." : "Keine Werte.")
                                .type(14).foregroundStyle(Palette.inkSoft)
                                .padding(30)
                        }
                        Color.clear.frame(height: 24)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Palette.canvas)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1, sections, proxy, layoutKey); return .handled }
                .onKeyPress(.upArrow) { move(-1, sections, proxy, layoutKey); return .handled }
                .onKeyPress(.escape) { model.selection = nil; return .handled }
                .onKeyPress(.return) {
                    if let id = model.selection { model.editor = .edit(id) }
                    return .handled
                }
            }
        }
        .onAppear { focused = true }
    }

    static func rowID(_ id: UUID, _ layout: String) -> String { "\(id.uuidString)|\(layout)" }

    private func move(_ delta: Int, _ sections: [TableSection], _ proxy: ScrollViewProxy, _ layout: String) {
        let ids = sections.filter { !model.local.collapsedSections.contains($0.id) }.flatMap { $0.rows.map(\.id) }
        guard !ids.isEmpty else { return }
        let i = model.selection.flatMap { ids.firstIndex(of: $0) }
        let next = i.map { max(0, min(ids.count - 1, $0 + delta)) } ?? 0
        model.selection = ids[next]
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(Self.rowID(ids[next], layout)) }
    }
}

// MARK: Header

struct HeaderRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    var columns: [Column]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { c in
                let active = c.sortKey != nil && model.local.sort == c.sortKey
                let label = HStack(spacing: 3) {
                    if c.trailing { Spacer(minLength: 0) }
                    Text(c.title(model.depot.rules)).type(12, active ? .semibold : .regular)
                        .foregroundStyle(active ? Palette.ink : Palette.inkSoft)
                        .lineLimit(1)
                    if active {
                        Image(systemName: model.local.sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8 * scale, weight: .bold))
                            .foregroundStyle(Palette.ink)
                    }
                    if !c.trailing { Spacer(minLength: 0) }
                }
                ZStack {
                    if let k = c.sortKey {
                        Button { model.toggleSort(k) } label: { label.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .help("Nach \(c.title(model.depot.rules)) sortieren")
                    } else {
                        label
                    }
                }
                .frame(width: c == .name ? nil : c.width * scale, alignment: c.trailing ? .trailing : .leading)
                .frame(maxWidth: c == .name ? .infinity : nil, alignment: .leading)
                .padding(.trailing, c.trailing ? 10 * scale : 0)
                .padding(.leading, c == .gauge ? 8 * scale : 0)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 30 * scale)
        .background(Palette.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
        .contextMenu { ColumnMenu() }
    }
}

struct ColumnMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Section("Spalten zeigen") {
            ForEach(Column.allCases.filter { $0 != .name && $0 != .gauge }) { c in
                Toggle(c.title(model.depot.rules), isOn: Binding(get: { !model.local.hiddenColumns.contains(c.rawValue) }, set: { on in
                    model.updateLocal { l in if on { l.hiddenColumns.remove(c.rawValue) } else { l.hiddenColumns.insert(c.rawValue) } }
                }))
            }
        }
    }
}

// MARK: Section header

struct SectionHeaderRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    var section: TableSection
    var columns: [Column]

    var body: some View {
        let t = section.totals
        let collapsed = model.local.collapsedSections.contains(section.id)
        HStack(spacing: 0) {
            ForEach(columns) { c in
                // ZStack with a clear base: every column keeps its width even when it shows nothing.
                ZStack(alignment: c.trailing ? .trailing : .leading) {
                    Color.clear.frame(height: 1)
                    switch c {
                    case .name:
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10 * scale, weight: .semibold))
                                .rotationEffect(.degrees(collapsed ? 0 : 90))
                                .foregroundStyle(Palette.inkSoft)
                            Text(section.title).type(15, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(countText(section)).type(12).foregroundStyle(Palette.inkSoft).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    case .gauge:
                        MiniCounts(totals: t)
                    case .value:
                        if t.holdings > 0 { Text(Format.eur(t.value, decimals: 0)).type(14, .semibold).foregroundStyle(Palette.ink) }
                    case .sincePurchase:
                        if t.holdings > 0, let p = t.sincePurchasePercent {
                            Text(Format.pct(p, signed: true)).type(13, .semibold).foregroundStyle(Palette.change(p))
                        }
                    case .day:
                        if t.holdings > 0, let p = t.dayPercent {
                            Text(Format.pct(p, signed: true)).type(13, .semibold).foregroundStyle(Palette.change(p))
                        }
                    default:
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: c == .name ? nil : c.width * scale, alignment: c.trailing ? .trailing : .leading)
                .frame(maxWidth: c == .name ? .infinity : nil, alignment: .leading)
                .padding(.trailing, c.trailing ? 10 * scale : 0)
                .padding(.leading, c == .gauge ? 8 * scale : 0)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 38 * scale)
        .background(Palette.band)
        .overlay(alignment: .leading) {
            Rectangle().fill(section.color ?? (section.isWatchlist ? Palette.inkFaint : Palette.signal)).frame(width: 4)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.toggleSection(section.id) } }
    }

    private func countText(_ s: TableSection) -> String {
        let n = s.rows.count
        return n == 1 ? "1 Wert" : "\(n) Werte"
    }
}

struct MiniCounts: View {
    var totals: Totals
    var body: some View {
        HStack(spacing: 8) {
            ForEach([AmpelState.red, .yellow, .green], id: \.self) { s in
                let n = totals.counts[s] ?? 0
                if n > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Palette.ampel(s)).frame(width: 7, height: 7)
                        Text("\(n)").type(12, .medium).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            if !totals.stale.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Palette.caution)
                    Text("\(totals.stale.count)").type(12, .medium).foregroundStyle(Palette.inkSoft)
                }
                .help(totals.stale.count == 1 ? "1 Wert ohne aktuelle Kurse" : "\(totals.stale.count) Werte ohne aktuelle Kurse")
            }
        }
    }
}

// MARK: Row

struct QuoteRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    var row: TableRow
    var columns: [Column]
    var zebra: Bool
    @State private var hover = false

    var body: some View {
        let selected = model.selection == row.id
        HStack(spacing: 0) {
            ForEach(columns) { c in
                cell(c)
                    .frame(width: c == .name ? nil : c.width * scale, alignment: c.trailing ? .trailing : .leading)
                    .frame(maxWidth: c == .name ? .infinity : nil, alignment: .leading)
                    .padding(.trailing, c.trailing ? 10 * scale : 0)
                    .padding(.leading, c == .gauge ? 8 * scale : 0)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight * scale)
        .background(rowBackground(selected: selected))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Palette.signal).frame(width: 4) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.selection = selected ? nil : row.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selection = row.id
            model.editor = .edit(row.id)
        })
        .contextMenu {
            Button("Bearbeiten …") { model.editor = .edit(row.id) }
            Button("Daten neu laden") { model.reloadData(for: row.id) }
            Divider()
            Button("Löschen", role: .destructive) { model.delete(row.id) }
        }
        .help(helpText)
    }

    private func rowBackground(selected: Bool) -> Color {
        if selected { return Palette.selection }
        if hover { return Palette.band }
        return zebra ? Palette.zebra : Palette.surface
    }

    private var helpText: String {
        var parts: [String] = []
        if let m = row.metrics, m.currency != "EUR", let pl = m.priceLocal { parts.append("Kurs an der Börse: \(Format.money(pl, m.currency))") }
        if let f = row.freshness, f.level != .ok, f.level != .pending, !f.detail.isEmpty {
            parts.append(f.detail)
        } else if let e = row.status?.lastError {
            parts.append(e)
        }
        if let note = row.status?.plausibilityNote { parts.append(note) }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private func cell(_ c: Column) -> some View {
        let m = row.metrics
        let watch = row.position.isWatchOnly
        switch c {
        case .name:
            NameCell(row: row)
        case .gauge:
            // Without current data the reading is the last known one: shown faded, not as a live signal.
            HStack(spacing: 8) {
                LineGauge(metrics: m, rules: model.depot.rules)
                    .frame(width: 78 * scale, height: 16 * scale)
                Text(m?.ampel.distancePercent.map { Format.pct($0, signed: true) } ?? Placeholder.missing)
                    .type(13, .medium)
                    .foregroundStyle(m.map { Palette.ampel($0.ampel.state) } ?? Palette.inkFaint)
                    .lineLimit(1)
            }
            .opacity(row.isStale ? 0.38 : 1)
        case .price:
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 2) {
                    Text(m?.priceEUR.map { Format.eur($0) } ?? Placeholder.missing).type(14, .medium).foregroundStyle(Palette.ink)
                    if m?.quoteSuspect == true {
                        Text("?").type(13, .bold).foregroundStyle(Palette.caution)
                            .help("Großer Kurssprung, von keiner zweiten Quelle bestätigt")
                    }
                }
                HStack(spacing: 3) {
                    if row.isStale {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9 * scale))
                    }
                    Text(m?.quoteTime.map { Format.time($0) } ?? (row.status?.isLoading == true ? "lädt" : " "))
                        .type(11, row.isStale ? .semibold : .regular)
                }
                .foregroundStyle(row.isStale ? Palette.caution : Palette.inkFaint)
            }
        case .day:
            pct(m?.dayChangePercent)
        case .quantity:
            Text(watch ? "" : Format.qty(row.position.quantity)).type(13).foregroundStyle(Palette.inkSoft)
        case .avgPrice:
            Text(watch ? "" : row.position.averagePriceEUR.map { Format.eur($0) } ?? "").type(13).foregroundStyle(Palette.inkSoft)
        case .value:
            Text(watch ? "" : m?.valueEUR.map { Format.eur($0, decimals: $0 >= 10_000 ? 0 : 2) } ?? Placeholder.missing)
                .type(14, .medium).foregroundStyle(Palette.ink)
        case .sincePurchase:
            if watch {
                Text("")
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(m?.sincePurchasePercent.map { Format.pct($0, signed: true) } ?? Placeholder.missing)
                        .type(14, .medium).foregroundStyle(Palette.change(m?.sincePurchasePercent))
                    Text(m?.sincePurchaseEUR.map { Format.signedEUR($0) } ?? " ")
                        .type(11).foregroundStyle(Palette.change(m?.sincePurchaseEUR).opacity(0.85))
                }
            }
        case .ytd:
            pct(m?.ytdPercent)
        case .days30:
            pct(m?.days30Percent)
        }
    }

    private func pct(_ v: Double?) -> some View {
        Text(v.map { Format.pct($0, signed: true) } ?? Placeholder.missing)
            .type(14, .medium)
            .foregroundStyle(Palette.change(v))
    }
}

struct NameCell: View {
    @Environment(\.uiScale) private var scale
    var row: TableRow

    var body: some View {
        let m = row.metrics
        HStack(spacing: 10) {
            AmpelDot(state: m?.ampel.state ?? .unknown, fresh: m?.ampel.isFresh == true, dimmed: row.isStale)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.position.name).type(14, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                // Chips are dropped when the column is too narrow; the ring on the dot and the warning in the price column remain.
                ViewThatFits(in: .horizontal) {
                    subline(withChip: true, withStale: true)
                    subline(withChip: false, withStale: true)
                    subline(withChip: false, withStale: false)
                }
            }
        }
    }

    @ViewBuilder
    private func subline(withChip: Bool, withStale: Bool) -> some View {
        let m = row.metrics
        HStack(spacing: 6) {
            Text(row.position.listing.ticker).type(11).foregroundStyle(Palette.inkSoft).lineLimit(1)
            Text(row.exchange?.badge ?? row.position.listing.exchangeID).type(11, .medium).foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, 4).padding(.vertical, 0.5)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.rule))
                .fixedSize()
            if withChip, let cr = m?.ampel.lastCrossing, m?.ampel.isFresh == true {
                Text((cr.direction == .down ? "\u{2193} seit " : "\u{2191} seit ") + Format.dayShort(cr.day))
                    .type(11, .semibold)
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 0.5)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 3))
                    .lineLimit(1)
                    .fixedSize()
                    .help(cr.direction == .down ? "Am \(Format.day(cr.day)) unter die Linie gefallen" : "Am \(Format.day(cr.day)) über die Linie gestiegen")
            }
            if withStale, row.isStale, let f = row.freshness {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9 * scale))
                    Text(f.headline).type(11, .semibold).lineLimit(1)
                }
                .foregroundStyle(Palette.caution)
                .padding(.horizontal, 5).padding(.vertical, 0.5)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.caution.opacity(0.7)))
                .fixedSize()
            } else if row.isStale || (m?.hasData != true && row.status?.lastError != nil && row.status?.isLoading != true) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10 * scale)).foregroundStyle(Palette.caution)
            }
        }
    }
}

struct AmpelDot: View {
    @Environment(\.uiScale) private var scale
    var state: AmpelState
    var fresh: Bool
    /// Last known state while data is missing: faded with a dashed outline.
    var dimmed = false

    var body: some View {
        ZStack {
            if fresh {
                Circle().stroke(Palette.signal, lineWidth: 2.5 * scale).frame(width: 17 * scale, height: 17 * scale)
                    .opacity(dimmed ? 0.4 : 1)
            }
            Circle().fill(Palette.ampel(state).opacity(dimmed ? 0.3 : 1)).frame(width: 11 * scale, height: 11 * scale)
            if dimmed {
                Circle().stroke(Palette.ampel(state), style: StrokeStyle(lineWidth: 1.2 * scale, dash: [2 * scale, 1.5 * scale]))
                    .frame(width: 11 * scale, height: 11 * scale)
            }
        }
        .frame(width: 18 * scale, height: 18 * scale)
        .accessibilityLabel(dimmed ? state.label + ", nicht aktuell" : state.label)
    }
}
