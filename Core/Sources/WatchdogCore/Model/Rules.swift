import Foundation

/// A line on the chart: the price itself or a moving average of closing prices.
public struct LineSpec: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, CaseIterable { case price, sma, ema }
    public var kind: Kind
    public var length: Int

    public init(_ kind: Kind, _ length: Int = 0) {
        self.kind = kind
        self.length = kind == .price ? 0 : max(2, length)
    }

    public static let price = LineSpec(.price)
    public static func sma(_ n: Int) -> LineSpec { LineSpec(.sma, n) }
    public static func ema(_ n: Int) -> LineSpec { LineSpec(.ema, n) }

    public var description: String {
        switch kind {
        case .price: return "Kurs"
        case .sma: return "\(length)-Tage-Linie"
        case .ema: return "\(length)-Tage-EMA"
        }
    }

    public var shortLabel: String {
        switch kind {
        case .price: return "Kurs"
        case .sma: return "\(length)er"
        case .ema: return "EMA \(length)"
        }
    }

    /// "200-Tage-Linie" for messages.
    public var longLabel: String {
        switch kind {
        case .price: return "Kurs"
        case .sma: return "\(length)-Tage-Linie"
        case .ema: return "EMA \(length)"
        }
    }
}

public enum PerformancePeriod: String, Codable, Sendable, CaseIterable {
    case day, days30, ytd, sincePurchase

    public var label: String {
        switch self {
        case .day: return "Heute"
        case .days30: return "30 Tage"
        case .ytd: return "Seit Jahresbeginn"
        case .sincePurchase: return "Seit Kauf"
        }
    }
}

public struct Condition: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// a is above b right now (state)
        case above
        /// a is below b right now (state)
        case below
        /// a crossed above b within the last `days` trading days (event)
        case crossesAbove
        /// a crossed below b within the last `days` trading days (event)
        case crossesBelow
        /// a is within `percent` of b (state)
        case near
        /// performance over `period` below `percent` (state)
        case changeBelow
        /// performance over `period` above `percent` (state)
        case changeAbove

        public var label: String {
        switch self {
            case .above: return "liegt über"
            case .below: return "liegt unter"
            case .crossesAbove: return "kreuzt nach oben"
            case .crossesBelow: return "kreuzt nach unten"
            case .near: return "ist nahe an"
            case .changeBelow: return "Veränderung kleiner als"
            case .changeAbove: return "Veränderung größer als"
            }
        }

        public var isEvent: Bool { self == .crossesAbove || self == .crossesBelow }
        public var usesLines: Bool { self != .changeBelow && self != .changeAbove }
    }

    public var kind: Kind
    public var a: LineSpec
    public var b: LineSpec
    public var days: Int
    public var percent: Double
    public var period: PerformancePeriod

    public init(kind: Kind, a: LineSpec = .price, b: LineSpec = .sma(200), days: Int = 5, percent: Double = 2, period: PerformancePeriod = .days30) {
        self.kind = kind
        self.a = a
        self.b = b
        self.days = days
        self.percent = percent
        self.period = period
    }

    /// Lines that must be computed to evaluate this condition.
    public var lines: [LineSpec] { kind.usesLines ? [a, b] : [] }

    public var summary: String {
        switch kind {
        case .above, .below, .crossesAbove, .crossesBelow:
            let base = "\(a) \(kind.label) \(b)"
            return kind.isEvent ? base + " (letzte \(days) Handelstage)" : base
        case .near:
            return "\(a) \(kind.label) \(b) (unter \(Self.pct(percent)) Abstand)"
        case .changeBelow, .changeAbove:
            return "\(period.label): \(kind.label) \(Self.pct(percent))"
        }
    }

    static func pct(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " %"
    }
}

public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
    case info, warning, alarm

    public var label: String {
        switch self {
        case .info: return "Hinweis"
        case .warning: return "Achtung"
        case .alarm: return "Alarm"
        }
    }

    private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
    public static func < (l: Severity, r: Severity) -> Bool { l.rank < r.rank }
}

public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var condition: Condition
    public var severity: Severity
    /// Send a notification when an event rule fires or a state rule becomes true.
    public var notify: Bool
    /// Show a badge in the table while the rule is active.
    public var showBadge: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, condition: Condition, severity: Severity, notify: Bool, showBadge: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.condition = condition
        self.severity = severity
        self.notify = notify
        self.showBadge = showBadge
    }

    /// What happened, for the title of a message ("fällt unter die 200-Tage-Linie").
    public var headline: String {
        let c = condition
        guard c.a == .price else { return name }
        switch c.kind {
        case .crossesBelow: return "fällt unter die \(c.b.longLabel)"
        case .crossesAbove: return "steigt über die \(c.b.longLabel)"
        case .below: return "liegt unter der \(c.b.longLabel)"
        case .above: return "liegt über der \(c.b.longLabel)"
        default: return name
        }
    }
}

/// Traffic light: green above the line, red below, yellow when closer than `yellowBandPercent`.
public struct AmpelConfig: Codable, Hashable, Sendable {
    public enum YellowMode: String, Codable, Sendable, CaseIterable {
        /// Yellow only while still above the line but close to it (red stays "below the line").
        case aboveOnly
        /// Yellow on both sides of the line.
        case bothSides

        public var label: String {
            switch self {
            case .aboveOnly: return "Nur knapp oberhalb (Rot bleibt \u{201E}unter der Linie\u{201C})"
            case .bothSides: return "Ober- und unterhalb der Linie"
            }
        }
    }

    public var line: LineSpec
    public var yellowBandPercent: Double
    public var yellowMode: YellowMode
    /// Crossings within this many trading days are marked as fresh.
    public var freshDays: Int

    public init(line: LineSpec = .sma(200), yellowBandPercent: Double = 2, yellowMode: YellowMode = .aboveOnly, freshDays: Int = 5) {
        self.line = line
        self.yellowBandPercent = yellowBandPercent
        self.yellowMode = yellowMode
        self.freshDays = freshDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AmpelConfig()
        line = c.value(.line, d.line)
        yellowBandPercent = c.value(.yellowBandPercent, d.yellowBandPercent)
        yellowMode = c.value(.yellowMode, d.yellowMode)
        freshDays = c.value(.freshDays, d.freshDays)
    }
}

public struct RuleSet: Codable, Hashable, Sendable {
    public var ampel: AmpelConfig
    public var rules: [Rule]
    /// Moving averages drawn in the chart.
    public var chartLines: [LineSpec]
    /// When true, crossings only count on completed daily closes, not on the live price.
    public var confirmOnClose: Bool

    public init(ampel: AmpelConfig = AmpelConfig(), rules: [Rule] = RuleSet.defaultRules, chartLines: [LineSpec] = [.sma(38), .sma(200)], confirmOnClose: Bool = false) {
        self.ampel = ampel
        self.rules = rules
        self.chartLines = chartLines
        self.confirmOnClose = confirmOnClose
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RuleSet()
        ampel = c.value(.ampel, d.ampel)
        rules = c.value(.rules, d.rules)
        chartLines = c.value(.chartLines, d.chartLines)
        confirmOnClose = c.value(.confirmOnClose, d.confirmOnClose)
    }

    // Fixed ids so that defaults can be recognised across devices.
    public static let crossDownID = UUID(uuidString: "0B5E0C1A-2000-4000-8000-000000000001")!
    public static let crossUpID = UUID(uuidString: "0B5E0C1A-2000-4000-8000-000000000002")!
    public static let deathCrossID = UUID(uuidString: "0B5E0C1A-2000-4000-8000-000000000003")!
    public static let goldenCrossID = UUID(uuidString: "0B5E0C1A-2000-4000-8000-000000000004")!
    public static let drop30ID = UUID(uuidString: "0B5E0C1A-2000-4000-8000-000000000005")!

    public static let defaultRules: [Rule] = [
        Rule(id: crossDownID, name: "Durchbruch der 200-Tage-Linie nach unten",
             condition: Condition(kind: .crossesBelow, a: .price, b: .sma(200), days: 5), severity: .alarm, notify: true),
        Rule(id: crossUpID, name: "Anstieg über die 200-Tage-Linie",
             condition: Condition(kind: .crossesAbove, a: .price, b: .sma(200), days: 5), severity: .info, notify: true),
        Rule(id: deathCrossID, name: "38er kreuzt 200er nach unten",
             enabled: false, condition: Condition(kind: .crossesBelow, a: .sma(38), b: .sma(200), days: 5), severity: .warning, notify: true),
        Rule(id: goldenCrossID, name: "38er kreuzt 200er nach oben",
             enabled: false, condition: Condition(kind: .crossesAbove, a: .sma(38), b: .sma(200), days: 5), severity: .info, notify: true),
        Rule(id: drop30ID, name: "Mehr als 15 % Verlust in 30 Tagen",
             enabled: false, condition: Condition(kind: .changeBelow, days: 0, percent: -15, period: .days30), severity: .warning, notify: true),
    ]

    /// All moving averages needed for chart, Ampel and rules.
    public var requiredLines: Set<LineSpec> {
        var s = Set(chartLines)
        s.insert(ampel.line)
        for r in rules where r.enabled { s.formUnion(r.condition.lines) }
        s.remove(.price)
        return s
    }

    /// Longest moving average, used to decide how much history is needed.
    public var maxLength: Int { requiredLines.map(\.length).max() ?? 200 }
}

public extension KeyedDecodingContainer {
    /// Decodes a value or returns the default when it is missing or malformed.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
