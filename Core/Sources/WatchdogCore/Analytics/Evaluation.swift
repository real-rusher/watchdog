import Foundation

public enum AmpelState: String, Codable, Sendable {
    case green, yellow, red, unknown

    public var label: String {
        switch self {
        case .green: return "Über der Linie"
        case .yellow: return "Knapp an der Linie"
        case .red: return "Unter der Linie"
        case .unknown: return "Zu wenig Daten"
        }
    }

    /// Sort rank: most urgent first.
    public var urgency: Int {
        switch self {
        case .red: return 0
        case .yellow: return 1
        case .green: return 2
        case .unknown: return 3
        }
    }
}

public struct CrossingInfo: Codable, Hashable, Sendable {
    public var day: DayKey
    public var direction: Indicators.Crossing.Direction
    /// Trading days since the crossing (0 = today / latest bar).
    public var sessionsAgo: Int
}

public struct AmpelReading: Hashable, Sendable {
    public var state: AmpelState
    public var lineValue: Double?
    /// (price / line - 1) * 100
    public var distancePercent: Double?
    public var lastCrossing: CrossingInfo?
    public var isFresh: Bool
}

public struct RuleHit: Hashable, Sendable {
    public var rule: Rule
    /// For event rules the day of the triggering crossing.
    public var eventDay: DayKey?
    public var direction: Indicators.Crossing.Direction?
    /// Stable key used to avoid notifying twice.
    public var dedupKey: String
}

/// Everything the table shows for one position. Prices in EUR unless stated otherwise.
public struct PositionMetrics: Sendable {
    public var positionID: UUID
    public var currency: String
    public var priceLocal: Double?
    public var priceEUR: Double?
    public var quoteTime: Date?
    public var quoteSource: ProviderID?
    public var isLive: Bool
    public var dayChangePercent: Double?
    public var dayChangeEUR: Double?
    public var quantity: Double
    public var valueEUR: Double?
    public var costEUR: Double?
    public var averagePriceEUR: Double?
    public var sincePurchaseEUR: Double?
    public var sincePurchasePercent: Double?
    public var ytdPercent: Double?
    public var days30Percent: Double?
    /// Latest values of all computed lines (local currency).
    public var lineValues: [LineSpec: Double]
    public var ampel: AmpelReading
    public var hits: [RuleHit]
    public var historyCount: Int
    public var lastBarDay: DayKey?
    /// Euro per unit used for the current price, and whether it is a live market rate (else the ECB reference rate).
    public var fxRateNow: Double?
    public var fxLive = false
    /// The live price is a large jump that no second source confirmed.
    public var quoteSuspect = false
    /// A second source confirmed a large jump.
    public var quoteConfirmedBy: ProviderID?

    public var hasData: Bool { priceLocal != nil }

    public func performance(_ p: PerformancePeriod) -> Double? {
        switch p {
        case .day: return dayChangePercent
        case .days30: return days30Percent
        case .ytd: return ytdPercent
        case .sincePurchase: return sincePurchasePercent
        }
    }
}

/// Converts an amount at a given day into EUR. Returns EUR per 1 unit of `currency`.
public typealias FXLookup = (_ currency: String, _ day: DayKey) -> Double?

public enum Evaluator {
    public static func evaluate(position: Position,
                                exchange: Exchange,
                                history: [Bar],
                                quote: Quote?,
                                currency: String,
                                rules: RuleSet,
                                fx: FXLookup,
                                liveRate: Double? = nil,
                                today: DayKey = DayKey.today(in: .berlin)) -> PositionMetrics {
        let series = LiveSeries(history: history, quote: quote, timeZone: exchange.tz)
        let closes = series.closes
        let n = closes.count
        func eurRate(_ day: DayKey) -> Double? { currency == "EUR" ? 1 : fx(currency, day) }

        var m = PositionMetrics(positionID: position.id, currency: currency, priceLocal: nil, priceEUR: nil, quoteTime: nil,
                                quoteSource: nil, isLive: series.lastIsLive, dayChangePercent: nil, dayChangeEUR: nil,
                                quantity: position.quantity, valueEUR: nil, costEUR: nil, averagePriceEUR: nil,
                                sincePurchaseEUR: nil, sincePurchasePercent: nil, ytdPercent: nil, days30Percent: nil,
                                lineValues: [:], ampel: AmpelReading(state: .unknown, lineValue: nil, distancePercent: nil, lastCrossing: nil, isFresh: false),
                                hits: [], historyCount: history.count, lastBarDay: history.last?.day)
        if !position.isWatchOnly {
            m.costEUR = position.hasCost ? position.totalCostEUR : nil
            m.averagePriceEUR = position.averagePriceEUR
        }
        guard n > 0, let lastDay = series.days.last else { return m }

        let price = closes[n - 1]
        m.priceLocal = price
        m.quoteTime = quote?.time ?? lastDay.date
        m.quoteSource = quote?.source
        if series.lastIsLive {
            m.quoteSuspect = quote?.suspect ?? false
            m.quoteConfirmedBy = quote?.confirmedBy
        }
        // Today's value with the current market rate when there is one (like a bank or Google would convert),
        // all reference values of past days with the ECB rate of their own day.
        let live = currency == "EUR" ? nil : liveRate
        let rateNow = live ?? eurRate(lastDay)
        if let r = rateNow { m.priceEUR = price * r }
        m.fxRateNow = currency == "EUR" ? nil : rateNow
        m.fxLive = live != nil

        // Day change: against the previous session close, both converted with their own day's rate.
        var prevClose: Double?
        var prevDay: DayKey?
        if n >= 2 {
            prevClose = closes[n - 2]
            prevDay = series.days[n - 2]
        }
        if let pc = quote?.previousClose, pc > 0, series.lastIsLive {
            prevClose = pc
            if prevDay == nil { prevDay = lastDay.adding(days: -1) }
        }
        if let pc = prevClose, let pd = prevDay, let r0 = eurRate(pd), let r1 = rateNow, pc > 0 {
            let a = price * r1, b = pc * r0
            m.dayChangePercent = (a / b - 1) * 100
            m.dayChangeEUR = (a - b) * max(position.quantity, 0)
        }

        // Position value and result since purchase.
        if !position.isWatchOnly, let pe = m.priceEUR {
            let value = pe * position.quantity
            m.valueEUR = value
            if let cost = m.costEUR, cost > 0 {
                m.sincePurchaseEUR = value - cost
                m.sincePurchasePercent = (value / cost - 1) * 100
            }
        }

        // Reference values for YTD and 30 days, in EUR.
        func change(since ref: DayKey) -> Double? {
            guard let i = series.index(onOrBefore: ref), i < n - 1 else { return nil }
            let d = series.days[i]
            guard let r0 = eurRate(d), let r1 = rateNow, closes[i] > 0 else { return nil }
            return (price * r1 / (closes[i] * r0) - 1) * 100
        }
        let ytdRef = DayKey(year: lastDay.year - 1, month: 12, day: 31)
        m.ytdPercent = change(since: ytdRef)
        m.days30Percent = change(since: lastDay.adding(days: -30))

        // Lines.
        var lines: [LineSpec: [Double?]] = [:]
        for spec in rules.requiredLines.union([rules.ampel.line]) {
            let values = Indicators.line(spec, closes: closes)
            lines[spec] = values
            if let v = values.last ?? nil { m.lineValues[spec] = v }
        }
        lines[.price] = closes.map { $0 }

        // Closes-only variant for confirmed crossings.
        // A suspect live price (big jump nobody confirmed) is shown but does not trigger crossings.
        let liveUnusable = rules.confirmOnClose || (quote?.suspect ?? false)
        let confirmedCount = series.lastIsLive && liveUnusable ? n - 1 : n

        // Ampel.
        let ampelLine = lines[rules.ampel.line] ?? []
        if let lv = ampelLine.last ?? nil, lv > 0 {
            let dist = (price / lv - 1) * 100
            var state: AmpelState = dist >= 0 ? .green : .red
            let band = rules.ampel.yellowBandPercent
            if band > 0 && abs(dist) < band {
                if rules.ampel.yellowMode == .bothSides || dist >= 0 { state = .yellow }
            }
            let cr = Indicators.crossings(Array(closes.prefix(confirmedCount)).map { $0 }, Array(ampelLine.prefix(confirmedCount)))
            var info: CrossingInfo?
            if let last = cr.last {
                info = CrossingInfo(day: series.days[last.index], direction: last.direction, sessionsAgo: confirmedCount - 1 - last.index)
            }
            m.ampel = AmpelReading(state: state, lineValue: lv, distancePercent: dist, lastCrossing: info,
                                   isFresh: (info?.sessionsAgo ?? Int.max) < rules.ampel.freshDays)
        }

        // Rules.
        for rule in rules.rules where rule.enabled {
            let c = rule.condition
            switch c.kind {
            case .above, .below, .near:
                guard let a = lines[c.a]?.last ?? nil, let b = lines[c.b]?.last ?? nil, b != 0 else { continue }
                let ok: Bool
                switch c.kind {
                case .above: ok = a > b
                case .below: ok = a < b
                default: ok = abs((a / b - 1) * 100) <= c.percent
                }
                if ok { m.hits.append(RuleHit(rule: rule, eventDay: nil, direction: nil, dedupKey: "\(rule.id)|state")) }
            case .crossesAbove, .crossesBelow:
                guard let la = lines[c.a], let lb = lines[c.b] else { continue }
                let cr = Indicators.crossings(Array(la.prefix(confirmedCount)), Array(lb.prefix(confirmedCount)))
                let want: Indicators.Crossing.Direction = c.kind == .crossesAbove ? .up : .down
                if let hit = cr.last(where: { $0.direction == want }), confirmedCount - 1 - hit.index < max(1, c.days) {
                    // Only the latest crossing counts; if the line was re-crossed afterwards the event is over.
                    if cr.last == hit {
                        let day = series.days[hit.index]
                        m.hits.append(RuleHit(rule: rule, eventDay: day, direction: want, dedupKey: "\(rule.id)|\(day.value)"))
                    }
                }
            case .changeBelow, .changeAbove:
                guard let v = m.performance(c.period) else { continue }
                let ok = c.kind == .changeBelow ? v < c.percent : v > c.percent
                if ok { m.hits.append(RuleHit(rule: rule, eventDay: nil, direction: nil, dedupKey: "\(rule.id)|state")) }
            }
        }
        return m
    }

    /// Chart data: closes and lines converted to EUR with each day's own exchange rate,
    /// so crossings appear exactly where they are in the listing currency.
    public struct ChartPoint: Hashable, Sendable {
        public var day: DayKey
        public var priceEUR: Double
        public var priceLocal: Double
        /// Lines in euro (each day with its own rate) and in the listing currency.
        public var lines: [LineSpec: Double]
        public var linesLocal: [LineSpec: Double]
        /// Euro per unit used for this day.
        public var rate: Double
    }

    public static func chart(history: [Bar], quote: Quote?, exchange: Exchange, currency: String, lines specs: [LineSpec],
                             from: DayKey, fx: FXLookup, liveRate: Double? = nil) -> [ChartPoint] {
        let series = LiveSeries(history: history, quote: quote, timeZone: exchange.tz)
        let computed = specs.map { ($0, Indicators.line($0, closes: series.closes)) }
        var out: [ChartPoint] = []
        out.reserveCapacity(series.count)
        var lastRate: Double? = nil
        for i in 0..<series.count where series.days[i] >= from {
            let d = series.days[i]
            // Every day with the ECB rate of that day; the newest point (today's price) with the current market rate.
            let isLast = i == series.count - 1
            let rate = currency == "EUR" ? 1 : ((isLast ? liveRate : nil) ?? fx(currency, d) ?? lastRate)
            guard let r = rate else { continue }
            lastRate = r
            var lv: [LineSpec: Double] = [:]
            var ll: [LineSpec: Double] = [:]
            for (spec, values) in computed {
                if let v = values[i] {
                    lv[spec] = v * r
                    ll[spec] = v
                }
            }
            out.append(ChartPoint(day: d, priceEUR: series.closes[i] * r, priceLocal: series.closes[i], lines: lv, linesLocal: ll, rate: r))
        }
        return out
    }
}
