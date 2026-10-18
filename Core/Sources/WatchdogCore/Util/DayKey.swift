import Foundation

/// A calendar day encoded as yyyymmdd (e.g. 20261016). Cheap to store, compare and hash.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let value: Int

    public init(_ value: Int) { self.value = value }

    public init(year: Int, month: Int, day: Int) {
        self.value = year * 10000 + month * 100 + day
    }

    /// Day of `date` as seen in `timeZone`.
    public init(date: Date, timeZone: TimeZone = .utc) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses "yyyy-MM-dd" (optionally followed by a time part).
    public init?(iso: String) {
        let s = iso.prefix(10)
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var year: Int { value / 10000 }
    public var month: Int { (value / 100) % 100 }
    public var day: Int { value % 100 }

    /// Noon UTC of this day; stable anchor for charts and date math.
    public var date: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .utc
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int) -> DayKey {
        DayKey(date: date.addingTimeInterval(Double(days) * 86400), timeZone: .utc)
    }

    /// Weekday 1 = Sunday ... 7 = Saturday (Gregorian convention).
    public var weekday: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .utc
        return cal.component(.weekday, from: date)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool { lhs.value < rhs.value }

    public static func today(in tz: TimeZone = .current) -> DayKey { DayKey(date: Date(), timeZone: tz) }

    /// Number of calendar days from `self` to `other`.
    public func days(to other: DayKey) -> Int {
        Int(((other.date.timeIntervalSince1970 - date.timeIntervalSince1970) / 86400).rounded())
    }

    // Codable as a plain integer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.value = try c.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

public extension TimeZone {
    static let utc = TimeZone(identifier: "UTC")!
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
}
