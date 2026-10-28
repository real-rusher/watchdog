import SwiftUI
import WatchdogCore

/// Where the price sits relative to the signal line, in one glance.
/// Centre tick = the line (200er). Left = below (red zone), right = above (green zone),
/// the yellow band marks "close to the line". A yellow ring flags a fresh crossing.
struct LineGauge: View {
    var metrics: PositionMetrics?
    var rules: RuleSet
    /// Percent shown at the outer edges.
    var range: Double = 25

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let mid = w / 2
            let cy = h / 2
            // Dot and ring stay inside the drawing area at every font size.
            let ringR = min(8.5, h / 2 - 1.3)
            let r: CGFloat = min(h / 2 - 1, 5.5, ringR - 2.6)
            let margin = ringR + 1.3
            func x(_ pct: Double) -> CGFloat { mid + CGFloat(max(-range, min(range, pct)) / range) * (w / 2 - margin) }

            // Zones
            let track = CGRect(x: 0, y: cy - 2, width: w, height: 4)
            ctx.fill(Path(roundedRect: CGRect(x: track.minX, y: track.minY, width: mid, height: track.height), cornerRadius: 2),
                     with: .color(Palette.down.opacity(0.22)))
            ctx.fill(Path(roundedRect: CGRect(x: mid, y: track.minY, width: mid, height: track.height), cornerRadius: 2),
                     with: .color(Palette.up.opacity(0.22)))
            let band = rules.ampel.yellowBandPercent
            if band > 0 {
                let left = rules.ampel.yellowMode == .bothSides ? x(-band) : mid
                ctx.fill(Path(CGRect(x: left, y: track.minY, width: x(band) - left, height: track.height)), with: .color(Palette.caution.opacity(0.75)))
            }
            // The line itself
            ctx.fill(Path(CGRect(x: mid - 1, y: 0, width: 2, height: h)), with: .color(Palette.ink.opacity(0.75)))

            guard let m = metrics, let d = m.ampel.distancePercent else {
                return
            }
            let px = x(d)
            if m.ampel.isFresh {
                let ring = CGRect(x: px - ringR, y: cy - ringR, width: ringR * 2, height: ringR * 2)
                ctx.stroke(Path(ellipseIn: ring), with: .color(Palette.signal), lineWidth: 2.2)
            }
            let dot = CGRect(x: px - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(Palette.surface))
            ctx.fill(Path(ellipseIn: dot), with: .color(Palette.ampel(m.ampel.state)))
            // Off-scale indicator
            if abs(d) > range {
                var tri = Path()
                let tx = d > 0 ? w - 1 : 1
                let dir: CGFloat = d > 0 ? -1 : 1
                tri.move(to: CGPoint(x: tx, y: cy))
                tri.addLine(to: CGPoint(x: tx + dir * 4, y: cy - 3.5))
                tri.addLine(to: CGPoint(x: tx + dir * 4, y: cy + 3.5))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(Palette.ampel(m.ampel.state)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        guard let m = metrics, let d = m.ampel.distancePercent else { return "Keine Daten" }
        return "\(m.ampel.state.label), \(Format.pct(d, signed: true)) Abstand zur \(rules.ampel.line)"
    }
}
