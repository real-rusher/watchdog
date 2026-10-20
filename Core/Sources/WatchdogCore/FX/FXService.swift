import Foundation

/// Immutable snapshot of exchange rates (units of currency per 1 EUR, ECB convention).
public struct FXTable: Codable, Sendable {
    public var rates: [String: [DayKey: Double]]
    private var sortedDays: [String: [DayKey]] = [:]

    enum CodingKeys: String, CodingKey { case rates }

    public init(rates: [String: [DayKey: Double]] = [:]) {
        self.rates = rates
        reindex()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: [String: Double]].self, forKey: .rates)
        var r: [String: [DayKey: Double]] = [:]
        for (cur, m) in raw {
            var dm: [DayKey: Double] = [:]
            for (k, v) in m { if let i = Int(k) { dm[DayKey(i)] = v } }
            r[cur] = dm
        }
        self.rates = r
        reindex()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: [String: Double]] = [:]
        for (cur, m) in rates { raw[cur] = Dictionary(uniqueKeysWithValues: m.map { (String($0.key.value), $0.value) }) }
        try c.encode(raw, forKey: .rates)
    }

    mutating func reindex() {
        sortedDays = rates.mapValues { $0.keys.sorted() }
    }

    public mutating func merge(_ currency: String, _ values: [DayKey: Double]) {
        var m = rates[currency] ?? [:]
        for (k, v) in values where v > 0 { m[k] = v }
        rates[currency] = m
        sortedDays[currency] = m.keys.sorted()
    }

    /// EUR per one unit of `currency` on `day` (last known rate on or before that day; first rate if the day is earlier).
    public func eurPerUnit(_ currency: String, _ day: DayKey) -> Double? {
        if currency == "EUR" { return 1 }
        guard let days = sortedDays[currency], !days.isEmpty, let map = rates[currency] else { return nil }
        var lo = 0, hi = days.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if days[mid] <= day { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let d = found >= 0 ? days[found] : days[0]
        guard let units = map[d], units > 0 else { return nil }
        return 1 / units
    }

    public func latestDay(_ currency: String) -> DayKey? { sortedDays[currency]?.last }
    public func earliestDay(_ currency: String) -> DayKey? { sortedDays[currency]?.first }

    public var lookup: FXLookup { { cur, day in self.eurPerUnit(cur, day) } }
}

/// Current market exchange rate (not the once-a-day ECB reference rate), used for today's values.
public struct LiveFX: Codable, Hashable, Sendable {
    /// Euro per one unit of the currency.
    public var eurPerUnit: Double
    /// Time of the rate at the source.
    public var time: Date
    public var fetchedAt: Date
    public var source: ProviderID

    public init(eurPerUnit: Double, time: Date, fetchedAt: Date = Date(), source: ProviderID) {
        self.eurPerUnit = eurPerUnit
        self.time = time
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Units of the currency per euro, the usual way to quote it (1 € = 177,82 ¥).
    public var unitsPerEUR: Double { 1 / eurPerUnit }
}

/// Loads ECB reference rates (via Frankfurter, falling back to the ECB XML feed).
public actor FXService {
    private var table: FXTable
    private let http: HTTPClient
    private var lastFetch: [String: Date] = [:]

    public init(http: HTTPClient, cached: FXTable = FXTable()) {
        self.http = http
        self.table = cached
    }

    public func current() -> FXTable { table }

    /// Makes sure rates for `currencies` exist from `from` until today. Returns true if anything changed.
    @discardableResult
    public func ensure(_ currencies: Set<String>, from: DayKey) async -> Bool {
        let needed = currencies.filter { $0 != "EUR" }
        guard !needed.isEmpty else { return false }
        let today = DayKey.today(in: .berlin)
        var changed = false
        var missingStart: [String: DayKey] = [:]
        for cur in needed {
            if let earliest = table.earliestDay(cur), let latest = table.latestDay(cur) {
                if earliest > from.adding(days: 5) { missingStart[cur] = from }
                else if latest < today, Date().timeIntervalSince(lastFetch[cur] ?? .distantPast) > 3 * 3600 {
                    missingStart[cur] = latest.adding(days: -3)
                }
            } else {
                missingStart[cur] = from
            }
        }
        guard !missingStart.isEmpty else { return false }
        // Group by start day so one request covers several currencies.
        let groups = Dictionary(grouping: missingStart, by: { $0.value })
        for (start, entries) in groups {
            let curs = entries.map(\.key).sorted()
            let ecb = curs.filter { CurrencyNormalizer.ecb.contains($0) }
            if !ecb.isEmpty {
                if let got = await fetchFrankfurter(ecb, from: start, to: today) {
                    for (c, v) in got { table.merge(c, v) }
                    changed = true
                } else if let got = await fetchECB(ecb, from: start) {
                    for (c, v) in got { table.merge(c, v) }
                    changed = true
                }
            }
            for c in curs { lastFetch[c] = Date() }
        }
        return changed
    }

    /// Adds rates obtained elsewhere (e.g. Yahoo "EURXXX=X") for currencies the ECB does not publish.
    public func merge(_ currency: String, _ values: [DayKey: Double]) {
        table.merge(currency, values)
    }

    private func fetchFrankfurter(_ curs: [String], from: DayKey, to: DayKey) async -> [String: [DayKey: Double]]? {
        var result: [String: [DayKey: Double]] = [:]
        // Request year by year so long ranges stay daily.
        var start = from
        while start <= to {
            let endOfYear = DayKey(year: start.year, month: 12, day: 31)
            let end = min(endOfYear, to)
            var ok = false
            for host in ["https://api.frankfurter.dev/v1", "https://api.frankfurter.app"] {
                let url = URL.make("\(host)/\(start.iso)..\(end.iso)", [("base", "EUR"), ("symbols", curs.joined(separator: ","))])
                guard let obj = try? await http.json(url) as? [String: Any], let rates = obj["rates"] as? [String: Any] else { continue }
                for (dayString, v) in rates {
                    guard let d = DayKey(iso: dayString), let m = v as? [String: Any] else { continue }
                    for (c, r) in m { if let x = Lenient.double(any: r) { result[c, default: [:]][d] = x } }
                }
                ok = true
                break
            }
            if !ok { return result.isEmpty ? nil : result }
            start = DayKey(year: start.year + 1, month: 1, day: 1)
        }
        return result
    }

    private func fetchECB(_ curs: [String], from: DayKey) async -> [String: [DayKey: Double]]? {
        let short = from.days(to: DayKey.today()) < 85
        let url = URL(string: short ? "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml" : "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml")!
        guard let (data, resp) = try? await http.get(url), resp.statusCode == 200, let xml = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseECB(xml, currencies: Set(curs), from: from)
    }

    /// Minimal parser for the ECB "Cube" XML.
    static func parseECB(_ xml: String, currencies: Set<String>, from: DayKey) -> [String: [DayKey: Double]] {
        var out: [String: [DayKey: Double]] = [:]
        var currentDay: DayKey?
        var idx = xml.startIndex
        while let r = xml.range(of: "<Cube ", range: idx..<xml.endIndex) {
            guard let end = xml.range(of: ">", range: r.upperBound..<xml.endIndex) else { break }
            let tag = String(xml[r.upperBound..<end.lowerBound])
            if let t = Self.attr("time", tag) {
                currentDay = DayKey(iso: t)
            } else if let c = Self.attr("currency", tag), let rate = Self.attr("rate", tag), let d = currentDay, d >= from, currencies.contains(c), let v = Double(rate) {
                out[c, default: [:]][d] = v
            }
            idx = end.upperBound
        }
        return out
    }

    private static func attr(_ name: String, _ tag: String) -> String? {
        for q in ["'", "\""] {
            if let r = tag.range(of: "\(name)=\(q)") {
                let rest = tag[r.upperBound...]
                if let e = rest.firstIndex(of: Character(q)) { return String(rest[..<e]) }
            }
        }
        return nil
    }
}
