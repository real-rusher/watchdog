import Foundation

/// OnVista (unofficial JSON API behind onvista.de). Strong for German venues incl. Tradegate, gettex and LS Exchange.
/// Symbol format: "<entityType>|<entityValue>|<idNotation>|<isin>" e.g. "STOCK|82849|9386131|DE0007164600" (ISIN optional).
public final class OnVistaProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.onvista
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 3, minInterval: 0.15)
    private let base = "https://api.onvista.de/api/v1"
    private let snapshots = SnapshotCache()

    public init() {}

    static let allowedTypes: Set<String> = ["STOCK", "ETF", "FUND", "CRYPTO", "INDEX", "PRECIOUS_METAL"]

    struct Instrument {
        var type: String
        var value: String
        var name: String
        var isin: String?
        var wkn: String?
        var symbol: String?
    }

    struct Venue {
        var codeMarket: String
        var marketName: String
        var idNotation: String
        var currency: String?
        var last: Double?
        var time: Date?
        var previous: Double?
    }

    // MARK: Search

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let instruments = try await findInstruments(query, env: env)
        var out: [SearchCandidate] = []
        for inst in instruments.prefix(4) {
            guard let venues = try? await snapshot(inst, env: env) else { continue }
            for v in venues {
                let ex = env.catalog.match(.onvista, code: v.codeMarket)
                let norm = CurrencyNormalizer.normalize(v.currency)
                out.append(SearchCandidate(provider: id, name: inst.name, isin: inst.isin, wkn: inst.wkn,
                                           ticker: inst.symbol ?? inst.wkn ?? inst.isin ?? inst.name,
                                           symbol: Self.symbol(inst, v.idNotation),
                                           exchangeID: ex?.id, exchangeLabel: v.marketName, currency: norm.code,
                                           assetType: Self.assetType(inst.type), lastPrice: v.last.map { $0 * norm.factor }))
            }
        }
        return out
    }

    static func assetType(_ t: String) -> AssetType {
        switch t {
        case "STOCK": return .stock
        case "ETF": return .etf
        case "FUND": return .fund
        case "CRYPTO": return .crypto
        default: return .other
        }
    }

    func findInstruments(_ query: String, env: ProviderEnvironment) async throws -> [Instrument] {
        let url = URL.make("\(base)/instruments/search/facet", [("searchValue", query)])
        let obj = try await gate.run { try await env.http.json(url) }
        guard let root = obj as? [String: Any], let facets = root["facets"] as? [[String: Any]] else { return [] }
        var out: [Instrument] = []
        for f in facets {
            guard let results = f["results"] as? [[String: Any]] else { continue }
            for r in results {
                guard let type = r.str("entityType"), Self.allowedTypes.contains(type), let value = r.str("entityValue") else { continue }
                out.append(Instrument(type: type, value: value, name: r.str("name") ?? query, isin: r.str("isin"), wkn: r.str("wkn"), symbol: r.str("symbol")))
            }
        }
        return out
    }

    private func snapshotPath(_ type: String) -> String? {
        switch type {
        case "STOCK": return "stocks"
        case "ETF": return "etfs"
        case "FUND": return "funds"
        case "INDEX": return "indices"
        case "CRYPTO": return "cryptos"
        case "PRECIOUS_METAL": return "precious_metals"
        default: return nil
        }
    }

    func snapshot(_ inst: Instrument, env: ProviderEnvironment) async throws -> [Venue] {
        let cacheKey = "\(inst.type)|\(inst.value)"
        if let cached = await snapshots.get(cacheKey) { return cached }
        var urls: [URL] = []
        if let path = snapshotPath(inst.type) {
            urls.append(URL(string: "\(base)/\(path)/\(inst.value)/snapshot")!)
            if let isin = inst.isin { urls.append(URL(string: "\(base)/\(path)/ISIN:\(isin)/snapshot")!) }
        }
        urls.append(URL(string: "\(base)/instruments/\(inst.type)/\(inst.value)/snapshot")!)
        var lastError: Error = ProviderError.notFound(inst.name)
        for url in urls {
            do {
                let obj = try await gate.run { try await env.http.json(url) }
                guard let root = obj as? [String: Any] else { continue }
                let venues = Self.parseVenues(root)
                if !venues.isEmpty {
                    await snapshots.put(cacheKey, venues)
                    return venues
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func parseVenues(_ root: [String: Any]) -> [Venue] {
        let list = (root.dict("quoteList")?["list"] as? [[String: Any]]) ?? []
        var out: [Venue] = []
        for q in list {
            guard let market = q.dict("market"), let code = market.str("codeMarket"), let idn = market.str("idNotation") ?? q.str("idNotation") else { continue }
            let time = q.str("datetimeLast").flatMap(Self.parseDate)
            out.append(Venue(codeMarket: code, marketName: market.str("name") ?? code, idNotation: idn, currency: q.str("isoCurrency"),
                             last: q.num("last"), time: time, previous: q.num("previousLast")))
        }
        if out.isEmpty, let q = root.dict("quote"), let market = q.dict("market"), let code = market.str("codeMarket"), let idn = market.str("idNotation") {
            out.append(Venue(codeMarket: code, marketName: market.str("name") ?? code, idNotation: idn, currency: q.str("isoCurrency"),
                             last: q.num("last"), time: q.str("datetimeLast").flatMap(Self.parseDate), previous: q.num("previousLast")))
        }
        return out
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Symbols

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.onvista), s.split(separator: "|").count >= 3 { return s }
        let codes = exchange.matchCodes(.onvista)
        guard !codes.isEmpty else { throw ProviderError.unsupported(exchange.name) }
        let queries = [ref.isin, ref.wkn, ref.name].compactMap { $0 }.filter { !$0.isEmpty }
        for q in queries {
            let instruments = try await findInstruments(q, env: env)
            let ranked = instruments.sorted { a, b in
                // Exact ISIN match first, then same name.
                let ai = (a.isin != nil && a.isin == ref.isin) ? 0 : 1
                let bi = (b.isin != nil && b.isin == ref.isin) ? 0 : 1
                return ai < bi
            }
            for inst in ranked.prefix(3) {
                if ref.isin != nil && inst.isin != nil && inst.isin != ref.isin { continue }
                if ref.isin == nil && Lenient.nameKey(inst.name) != Lenient.nameKey(ref.name) { continue }
                guard let venues = try? await snapshot(inst, env: env) else { continue }
                if let v = venues.first(where: { codes.contains($0.codeMarket) }) {
                    return Self.symbol(inst, v.idNotation)
                }
            }
        }
        throw ProviderError.notFound("\(ref.name) an \(exchange.name)")
    }

    // MARK: Data

    static func symbol(_ inst: Instrument, _ idNotation: String) -> String {
        "\(inst.type)|\(inst.value)|\(idNotation)" + (inst.isin.map { "|\($0)" } ?? "")
    }

    private func parts(_ symbol: String) throws -> (String, String, String, String?) {
        let p = symbol.split(separator: "|").map(String.init)
        guard p.count >= 3 else { throw ProviderError.parse("Symbol \(symbol)") }
        return (p[0], p[1], p[2], p.count > 3 ? p[3] : nil)
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let (type, value, idn, isin) = try parts(symbol)
        await snapshots.invalidate("\(type)|\(value)")
        let venues = try await snapshot(Instrument(type: type, value: value, name: symbol, isin: isin), env: env)
        guard let v = venues.first(where: { $0.idNotation == idn }), let last = v.last, last > 0 else {
            throw ProviderError.notFound("Notierung \(idn)")
        }
        let norm = CurrencyNormalizer.normalize(v.currency)
        return Quote(price: last * norm.factor, time: v.time ?? Date(), previousClose: v.previous.map { $0 * norm.factor },
                     currency: norm.code, source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let (type, value, idn, _) = try parts(symbol)
        let span = from.days(to: DayKey.today())
        let range = span > 365 * 5 ? "Y10" : span > 365 * 3 ? "Y5" : span > 365 ? "Y3" : span > 180 ? "Y1" : span > 90 ? "M6" : span > 30 ? "M3" : "M1"
        let url = URL.make("\(base)/instruments/\(type)/\(value)/eod_history", [("idNotation", idn), ("range", range), ("startDate", from.iso)])
        let obj = try await gate.run { try await env.http.json(url) }
        guard let root = obj as? [String: Any] else { throw ProviderError.parse("eod_history") }
        let norm = CurrencyNormalizer.normalize(root.str("isoCurrency"))
        let times = (root["datetimeLast"] as? [Any]) ?? []
        let closes = (root["last"] as? [Any]) ?? []
        let opens = root["first"] as? [Any]
        let highs = root["high"] as? [Any]
        let lows = root["low"] as? [Any]
        let vols = root["volume"] as? [Any]
        var bars: [Bar] = []
        for i in 0..<min(times.count, closes.count) {
            guard let t = Lenient.double(any: times[i]), let c = Lenient.double(any: closes[i]), c > 0 else { continue }
            func v(_ a: [Any]?) -> Double? { a.flatMap { i < $0.count ? Lenient.double(any: $0[i]) : nil }.map { $0 * norm.factor } }
            bars.append(Bar(day: DayKey(date: ProviderUtil.unixDate(t), timeZone: .utc), close: c * norm.factor,
                            open: v(opens), high: v(highs), low: v(lows), volume: vols.flatMap { i < $0.count ? Lenient.double(any: $0[i]) : nil }))
        }
        if bars.isEmpty { throw ProviderError.notFound("Historie \(symbol)") }
        return HistoryResult(bars: bars, currency: norm.code, source: id)
    }
}

/// Short-lived cache so a search followed by a quote does not fetch the same 60 kB snapshot twice.
actor SnapshotCache {
    private var store: [String: (Date, [OnVistaProvider.Venue])] = [:]

    func get(_ k: String) -> [OnVistaProvider.Venue]? {
        guard let (t, v) = store[k], Date().timeIntervalSince(t) < 30 else { return nil }
        return v
    }

    func put(_ k: String, _ v: [OnVistaProvider.Venue]) {
        store[k] = (Date(), v)
        if store.count > 300 { store = store.filter { Date().timeIntervalSince($0.value.0) < 30 } }
    }

    func invalidate(_ k: String) { store[k] = nil }
}
