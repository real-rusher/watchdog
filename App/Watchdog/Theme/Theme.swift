import SwiftUI
import AppKit
import CoreText
import WatchdogCore

/// Colour tokens. Every token has a light and a dark value; the app follows the system appearance.
enum Palette {
    private static func dyn(_ light: UInt32, _ dark: UInt32, alphaDark: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            let isDark = app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: alphaDark) : NSColor(hex: light)
        })
    }

    static let canvas = dyn(0xF3F4F1, 0x171A1D)
    static let surface = dyn(0xFCFCFA, 0x1E2226)
    static let zebra = dyn(0xF4F5F2, 0x22272B)
    static let band = dyn(0xE7E9E4, 0x2A3035)
    static let ink = dyn(0x1C2024, 0xE9ECE7)
    static let inkSoft = dyn(0x5A6269, 0xA2AAB0)
    static let inkFaint = dyn(0x8B9399, 0x6F787E)
    static let rule = dyn(0xD9DCD6, 0x343A40)
    static let signal = Color(nsColor: NSColor(hex: 0xFFD100))
    static let signalWash = dyn(0xFFF1A6, 0x4A4113)
    static let selection = dyn(0xFFF4BF, 0x3B3618)
    static let up = dyn(0x15774A, 0x4CC68A)
    static let down = dyn(0xC1352A, 0xFF7366)
    static let caution = dyn(0xD99E00, 0xF4C430)
    static let cautionWash = dyn(0xFBEBC4, 0x3D3219)
    static let unknown = dyn(0xB4BAB9, 0x4D555B)
    static let line38 = dyn(0x2D6CB5, 0x72AAF0)
    static let line200 = dyn(0xD2701F, 0xF29A4B)
    static let priceLine = dyn(0x1C2024, 0xECEFEA)

    static func change(_ v: Double?) -> Color {
        guard let v else { return inkFaint }
        if v > 0.0001 { return up }
        if v < -0.0001 { return down }
        return inkSoft
    }

    static func ampel(_ s: AmpelState) -> Color {
        switch s {
        case .green: return up
        case .yellow: return caution
        case .red: return down
        case .unknown: return unknown
        }
    }

    static func line(_ spec: LineSpec, index: Int) -> Color {
        if spec == .sma(200) { return line200 }
        if spec == .sma(38) { return line38 }
        let extra: [Color] = [dyn(0x7A4FB0, 0xB592F0), dyn(0x2E8C8C, 0x5FCACA), dyn(0x9C5B2E, 0xD79A6B)]
        return extra[index % extra.count]
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init?(hexString: String?) {
        guard var s = hexString?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(nsColor: NSColor(hex: v))
    }
}

/// Typography: IBM Plex Sans Condensed throughout; its figures are tabular by default.
enum Typo {
    enum Weight { case regular, medium, semibold, bold }

    static func registerFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for u in urls { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
    }

    static func name(_ w: Weight) -> String {
        switch w {
        case .regular: return "IBMPlexSansCond-Regular"
        case .medium: return "IBMPlexSansCond-Medium"
        case .semibold: return "IBMPlexSansCond-SemiBold"
        case .bold: return "IBMPlexSansCond-Bold"
        }
    }

    static func font(_ size: CGFloat, _ w: Weight = .regular, scale: CGFloat = 1) -> Font {
        .custom(name(w), fixedSize: (size * scale).rounded(.toNearestOrEven))
    }
}

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

/// Text style helper that respects the user's font size setting.
struct TypeStyle: ViewModifier {
    @Environment(\.uiScale) private var scale
    var size: CGFloat
    var weight: Typo.Weight
    func body(content: Content) -> some View {
        content.font(Typo.font(size, weight, scale: scale))
    }
}

extension View {
    func type(_ size: CGFloat, _ weight: Typo.Weight = .regular) -> some View {
        modifier(TypeStyle(size: size, weight: weight))
    }
}

/// Fixed metrics for the quote table.
enum Metrics {
    static let rowHeight: CGFloat = 44
    static let gutter: CGFloat = 16
}

enum Placeholder {
    /// Shown where a number is not available (no dashes in user facing text).
    static let missing = "·"
}
