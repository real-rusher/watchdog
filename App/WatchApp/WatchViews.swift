import SwiftUI
import WatchdogCore

@main
struct WatchdogWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    init() {
        Typo.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .onAppear { model.start() }
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await model.refreshIfOld() } }
        }
        .backgroundTask(.appRefresh("check")) {
            await model.backgroundCheck()
        }
    }
}

/// Values below the line first, then the freshly crossed: what needs a look.
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if let s = model.snapshot {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.belowCount == 1 ? "1 Wert unter der Linie" : "\(s.belowCount) Werte unter der Linie")
                                .type(16, .semibold).foregroundStyle(s.belowCount > 0 ? Palette.down : Palette.up)
                            if s.freshCount > 0 {
                                Text("\(s.freshCount) frisch gekreuzt").type(13, .semibold).foregroundStyle(Palette.signal)
                            }
                            Text("Stand \(Format.time(model.lastOwnCheck ?? s.createdAt))").type(12).foregroundStyle(Palette.inkSoft)
                        }
                        .listRowBackground(Color.clear)
                    }
                    ForEach(s.sortedRows) { r in
                        NavigationLink(value: r.id) { WatchRow(row: r) }
                    }
                }
                .navigationTitle("Watchdog")
                .navigationDestination(for: UUID.self) { id in WatchDetailView(id: id) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Noch keine Daten").type(17, .semibold)
                        Text("Watchdog auf dem iPhone einmal öffnen. Danach kommen die Werte von selbst auf die Uhr.")
                            .type(14).foregroundStyle(Palette.inkSoft)
                    }
                }
                .navigationTitle("Watchdog")
            }
        }
    }
}

struct WatchRow: View {
    let row: WatchSnapshot.Row

    var body: some View {
        HStack(spacing: 8) {
            AmpelDot(state: row.state, fresh: row.fresh, dimmed: row.stale)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).type(15, .medium).lineLimit(2)
                HStack(spacing: 6) {
                    Text(row.distance.map { Format.pct($0, signed: true) } ?? Placeholder.missing)
                        .type(13, .semibold).foregroundStyle(Palette.ampel(row.state))
                    Text(row.priceEUR.map { Format.eur($0) } ?? "").type(13).foregroundStyle(Palette.inkSoft)
                }
                .lineLimit(1)
            }
        }
    }
}

struct WatchDetailView: View {
    @Environment(WatchModel.self) private var model
    let id: UUID

    var body: some View {
        if let r = model.snapshot?.rows.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(r.name).type(17, .semibold)
                    Text(r.priceEUR.map { Format.eur($0) } ?? "Kein Kurs").type(22, .bold)
                    if r.currency != "EUR", let p = r.price { Text(Format.money(p, r.currency)).type(13).foregroundStyle(Palette.inkSoft) }
                    HStack(spacing: 6) {
                        AmpelDot(state: r.state, fresh: r.fresh, dimmed: r.stale)
                        Text(r.state.label).type(14, .semibold).foregroundStyle(Palette.ampel(r.state))
                    }
                    if let d = r.distance { line("Abstand", Format.pct(d, signed: true)) }
                    if let l = r.line, let rate = r.eurPerUnit { line("Linie", Format.eur(l * rate)) }
                    if let day = r.crossingDay, let down = r.crossingDown {
                        line(down ? "Unter die Linie" : "Über die Linie", "am \(Format.dayShort(day))")
                    }
                    if let t = r.quoteTime { line("Kurs von", Format.time(t)) }
                    line(r.held ? "Im Depot" : "Beobachtung", "\(r.listing.ticker) \(r.exchangeBadge)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).type(12).foregroundStyle(Palette.inkSoft)
            Text(value).type(15, .medium)
        }
    }
}
