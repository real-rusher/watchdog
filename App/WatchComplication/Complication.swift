import WidgetKit
import SwiftUI
import WatchdogCore

struct BelowLineEntry: TimelineEntry {
    let date: Date
    /// nil while the Watch has no data yet.
    let below: Int?
    let fresh: Int
    let names: [String]

    static let sample = BelowLineEntry(date: Date(), below: 3, fresh: 1, names: ["Cameco", "Paladin Energy"])

    static func current() -> BelowLineEntry {
        guard let s = SnapshotStore.load() else { return BelowLineEntry(date: Date(), below: nil, fresh: 0, names: []) }
        let red = s.sortedRows.filter { $0.state == .red }
        return BelowLineEntry(date: Date(), below: red.count, fresh: s.freshCount, names: red.map(\.name))
    }
}

struct BelowLineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BelowLineEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (BelowLineEntry) -> Void) {
        completion(context.isPreview ? .sample : .current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BelowLineEntry>) -> Void) {
        // The app reloads the complication after every new reading; this is only the fallback.
        completion(Timeline(entries: [.current()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct BelowLineView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BelowLineEntry

    private var count: String { entry.below.map(String.init) ?? "·" }
    private var color: Color { (entry.below ?? 0) > 0 ? .red : .green }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text(count).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
                    Text("unter").font(.system(size: 10, weight: .medium))
                }
            }
            .widgetAccentable()
        case .accessoryCorner:
            Text(count).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
                .widgetLabel { Text("unter der Linie") }
        case .accessoryInline:
            Text(entry.below.map { $0 == 1 ? "1 Wert unter der Linie" : "\($0) Werte unter der Linie" } ?? "Watchdog")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.below.map { $0 == 1 ? "1 unter der Linie" : "\($0) unter der Linie" } ?? "Watchdog")
                    .font(.headline).foregroundStyle(color).widgetAccentable()
                ForEach(entry.names.prefix(2), id: \.self) { Text($0).font(.caption).lineLimit(1) }
                if entry.fresh > 0 { Text("\(entry.fresh) frisch gekreuzt").font(.caption2).foregroundStyle(.yellow) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct WatchdogComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "belowLine", provider: BelowLineProvider()) { entry in
            BelowLineView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unter der Linie")
        .description("Wie viele Werte unter der 200-Tage-Linie liegen.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
