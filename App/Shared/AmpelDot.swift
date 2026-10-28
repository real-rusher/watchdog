import SwiftUI
import WatchdogCore

/// Traffic light dot; a yellow ring marks a fresh crossing, a dashed outline data that is not current.
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
