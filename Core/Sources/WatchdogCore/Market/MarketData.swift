import Foundation

/// One daily bar in the listing currency (already normalized, e.g. pence converted to pounds).
public struct Bar: Codable, Hashable, Sendable {
    public var day: DayKey
    public var close: Double
    public var open: Double?
    public var high: Double?
    public var low: Double?
    public var volume: Double?

    public init(day: DayKey, close: Double, open: Double? = nil, high: Double? = nil, low: Double? = nil, volume: Double? = nil) {
        self.day = day
        self.close = close
        self.open = open
        self.high = high
        self.low = low
        self.volume = volume
    }

    enum CodingKeys: String, CodingKey { case day = "d", close = "c", open = "o", high = "h", low = "l", volume = "v" }
}

/// Latest price of a listing.
public struct Quote: Codable, Hashable, Sendable {
    public var price: Double
    /// Time of the last trade or price.
    public var time: Date
    /// Close of the previous session if the provider reports it.
    public var previousClose: Double?
    public var currency: String
    public var source: ProviderID
    /// When Watchdog received it.
    public var fetchedAt: Date
    /// A second source reported the same price for a large move.
    public var confirmedBy: ProviderID?
    /// Large move that no second source confirmed: shown, but not used for alarms.
    public var suspect: Bool

    public init(price: Double, time: Date, previousClose: Double?, currency: String, source: ProviderID, fetchedAt: Date = Date(),
                confirmedBy: ProviderID? = nil, suspect: Bool = false) {
        self.price = price
        self.time = time
        self.previousClose = previousClose
        self.currency = currency
        self.source = source
        self.fetchedAt = fetchedAt
        self.confirmedBy = confirmedBy
        self.suspect = suspect
    }

    enum CodingKeys: String, CodingKey { case price, time, previousClose, currency, source, fetchedAt, confirmedBy, suspect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        price = try c.decode(Double.self, forKey: .price)
        time = try c.decode(Date.self, forKey: .time)
        previousClose = try c.decodeIfPresent(Double.self, forKey: .previousClose)
        currency = try c.decode(String.self, forKey: .currency)
        source = try c.decode(ProviderID.self, forKey: .source)
        fetchedAt = (try? c.decode(Date.self, forKey: .fetchedAt)) ?? time
        confirmedBy = try? c.decodeIfPresent(ProviderID.self, forKey: .confirmedBy)
        suspect = (try? c.decodeIfPresent(Bool.self, forKey: .suspect)) ?? false
    }
}

/// Result of a history request.
public struct HistoryResult: Sendable {
    public var bars: [Bar]
    public var currency: String
    public var source: ProviderID

    public init(bars: [Bar], currency: String, source: ProviderID) {
        self.bars = bars.sorted { $0.day < $1.day }
        self.currency = currency
        self.source = source
    }
}

/// Cached daily history of one listing.
public struct PriceHistory: Codable, Sendable {
    public var listingKey: String
    public var currency: String
    public var bars: [Bar]
    public var source: ProviderID
    public var updatedAt: Date
    /// First day that was requested; tells whether a longer range must be fetched.
    public var coveredFrom: DayKey

    public init(listingKey: String, currency: String, bars: [Bar], source: ProviderID, updatedAt: Date = Date(), coveredFrom: DayKey) {
        self.listingKey = listingKey
        self.currency = currency
        self.bars = bars
        self.source = source
        self.updatedAt = updatedAt
        self.coveredFrom = coveredFrom
    }

    public var lastDay: DayKey? { bars.last?.day }

    /// Merges newer bars into the cache; newer data wins for overlapping days.
    public mutating func merge(_ newBars: [Bar], source: ProviderID) {
        guard !newBars.isEmpty else { return }
        var map = Dictionary(bars.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for b in newBars where b.close.isFinite && b.close > 0 { map[b.day] = b }
        bars = map.values.sorted { $0.day < $1.day }
        self.source = source
        updatedAt = Date()
    }
}

/// Close prices with today's live price folded in.
public struct LiveSeries: Sendable {
    public var days: [DayKey]
    public var closes: [Double]
    /// True when the last element comes from the live quote and not from a completed daily bar.
    public var lastIsLive: Bool

    public init(history: [Bar], quote: Quote?, timeZone: TimeZone) {
        var days = history.map(\.day)
        var closes = history.map(\.close)
        var live = false
        if let q = quote, q.price > 0 {
            let qd = DayKey(date: q.time, timeZone: timeZone)
            if let last = days.last {
                if qd > last {
                    days.append(qd)
                    closes.append(q.price)
                    live = true
                } else if qd == last {
                    closes[closes.count - 1] = q.price
                    live = true
                }
            } else {
                days = [qd]
                closes = [q.price]
                live = true
            }
        }
        self.days = days
        self.closes = closes
        self.lastIsLive = live
    }

    public var count: Int { closes.count }

    /// Index of the last element on or before `day`.
    public func index(onOrBefore day: DayKey) -> Int? {
        var lo = 0, hi = days.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if days[mid] <= day { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}
