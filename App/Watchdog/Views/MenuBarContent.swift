import SwiftUI
import WatchdogCore

/// Small panel under the menu bar icon: what needs attention right now.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Red, yellow and freshly crossed values; fresh ones first, then the most urgent.
    static func attention(_ rows: [TableRow]) -> [TableRow] {
        func needsLook(_ r: TableRow) -> Bool {
            guard let a = r.metrics?.ampel else { return false }
            return a.state == .red || a.state == .yellow || a.isFresh
        }
        func rank(_ r: TableRow) -> (Int, Int, Double) {
            let a = r.metrics?.ampel
            let fresh = a?.isFresh == true ? 0 : 1
            let urgency = a?.state.urgency ?? 3
            let distance = a?.distancePercent ?? 0
            return (fresh, urgency, distance)
        }
        return rows.filter(needsLook).sorted { rank($0) < rank($1) }
    }

    var body: some View {
        let t = model.totals
        let attention = Self.attention(model.allRows)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Watchdog").type(16, .semibold).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(model.isRefreshing ? "aktualisiert …" : model.lastRefreshText).type(11).foregroundStyle(Palette.inkFaint)
                }
                if t.holdings > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Format.eur(t.value, decimals: 0)).type(20, .semibold).foregroundStyle(Palette.ink)
                        if let p = t.dayPercent { Text(Format.pct(p, signed: true) + " heute").type(13, .medium).foregroundStyle(Palette.change(p)) }
                    }
                }
                SignalBar(totals: t)
                if !t.stale.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Palette.caution)
                        Text(t.stale.count == 1 ? "1 Wert ohne aktuelle Kurse: \(t.stale[0].name)" : "\(t.stale.count) Werte ohne aktuelle Kurse")
                            .type(12, .medium).foregroundStyle(Palette.ink).lineLimit(2)
                    }
                    .help(t.stale.map { "\($0.name): \($0.headline)" }.joined(separator: "\n"))
                }
            }
            .padding(14)
            Divider()
            if attention.isEmpty {
                Text(model.depot.positions.isEmpty ? "Noch keine Werte angelegt." : "Alle Werte liegen über ihrer Linie.")
                    .type(13).foregroundStyle(Palette.inkSoft)
                    .padding(14)
            } else {
                Text("Hinschauen").type(12, .semibold).foregroundStyle(Palette.inkSoft).padding(.horizontal, 14).padding(.top, 10)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(attention.prefix(30)) { r in
                            Button {
                                model.selection = r.id
                                openWindow(id: "main")
                                NSApp.activate(ignoringOtherApps: true)
                            } label: {
                                HStack(spacing: 8) {
                                    AmpelDot(state: r.metrics?.ampel.state ?? .unknown, fresh: r.metrics?.ampel.isFresh == true, dimmed: r.isStale)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(r.position.name).type(13, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                                        if let c = r.metrics?.ampel.lastCrossing, r.metrics?.ampel.isFresh == true {
                                            Text("\(c.direction == .down ? "unter" : "über") die Linie am \(Format.dayShort(c.day))").type(11).foregroundStyle(Palette.inkSoft)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    Text(r.metrics?.ampel.distancePercent.map { Format.pct($0, signed: true) } ?? "").type(13, .medium)
                                        .foregroundStyle(Palette.ampel(r.metrics?.ampel.state ?? .unknown))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Button("Watchdog öffnen") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button {
                    model.refresh(force: true)
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Jetzt aktualisieren")
                    .disabled(model.isRefreshing)
                SettingsLink { Image(systemName: "gearshape") }.help("Einstellungen")
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("Watchdog beenden (dann gibt es keine Mitteilungen mehr)")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 340)
        .background(Palette.surface)
    }
}
