import Foundation

public typealias ExchangeID = String

/// A trading venue and how each data provider addresses it.
public struct Exchange: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case exchange, crypto }

    public var id: ExchangeID
    public var name: String
    /// Short label for the table, max ~6 characters.
    public var badge: String
    public var country: String
    public var currency: String
    public var timeZone: String
    /// Local opening time in minutes after midnight.
    public var opens: Int
    /// Local closing time in minutes after midnight.
    public var closes: Int
    public var kind: Kind
    /// Provider specific codes. Keys are `ProviderID.rawValue` plus optional "<provider>.match" keys
    /// holding comma separated alternative codes used when mapping search results.
    public var codes: [String: String]
    /// Extra names used when importing CSV files ("Tokio", "TSE", ...).
    public var aliases: [String]
    /// Shown in the exchange picker.
    public var isActive: Bool
    public var isCustom: Bool

    public init(id: ExchangeID, name: String, badge: String, country: String, currency: String, timeZone: String,
                opens: Int, closes: Int, kind: Kind = .exchange, codes: [String: String], aliases: [String] = [],
                isActive: Bool = true, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.badge = badge
        self.country = country
        self.currency = currency
        self.timeZone = timeZone
        self.opens = opens
        self.closes = closes
        self.kind = kind
        self.codes = codes
        self.aliases = aliases
        self.isActive = isActive
        self.isCustom = isCustom
    }

    public func code(_ p: ProviderID) -> String? { codes[p.rawValue] }

    /// All codes of a provider that map to this exchange (primary first).
    public func matchCodes(_ p: ProviderID) -> [String] {
        var r: [String] = []
        if let c = codes[p.rawValue] { r.append(c) }
        if let m = codes[p.rawValue + ".match"] {
            r += m.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return r
    }

    public func supports(_ p: ProviderID) -> Bool { codes[p.rawValue] != nil }

    public var tz: TimeZone { TimeZone(identifier: timeZone) ?? .berlin }

    /// Whether the venue is in its regular session at `date` (holidays are not modelled).
    public func isOpen(at date: Date = Date()) -> Bool {
        if kind == .crypto { return true }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, wd != 1, wd != 7 else { return false }
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m >= opens && m < closes
    }

    /// Minutes since the close of today's session (negative before close, nil on weekends).
    public func minutesSinceClose(at date: Date = Date()) -> Int? {
        if kind == .crypto { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, wd != 1, wd != 7 else { return nil }
        return (c.hour ?? 0) * 60 + (c.minute ?? 0) - closes
    }

    /// The most recent day that should have a complete daily bar.
    public func lastCompletedSession(at date: Date = Date()) -> DayKey {
        var day = DayKey(date: date, timeZone: tz)
        if kind == .crypto { return day.adding(days: -1) }
        if let since = minutesSinceClose(at: date), since >= 0 {
            // today's session is over
        } else {
            day = day.adding(days: -1)
        }
        while day.weekday == 1 || day.weekday == 7 { day = day.adding(days: -1) }
        return day
    }

    /// Minutes since today's session opened (only meaningful while open; nil for crypto and weekends).
    public func minutesSinceOpen(at date: Date = Date()) -> Int? {
        if kind == .crypto { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, wd != 1, wd != 7 else { return nil }
        return (c.hour ?? 0) * 60 + (c.minute ?? 0) - opens
    }

    /// Trading days (Mon to Fri) after `from` up to and including `to`. Crypto counts every day.
    public func sessions(after from: DayKey, upTo to: DayKey) -> Int {
        guard to > from else { return 0 }
        var n = 0
        var d = from.adding(days: 1)
        while d <= to {
            if kind == .crypto || (d.weekday != 1 && d.weekday != 7) { n += 1 }
            d = d.adding(days: 1)
        }
        return n
    }

    public var hoursText: String {
        if kind == .crypto { return "rund um die Uhr" }
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(hm(opens)) bis \(hm(closes)) Ortszeit"
    }
}
