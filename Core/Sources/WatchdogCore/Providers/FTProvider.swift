import Foundation

/// Financial Times markets data (unofficial). Global coverage, daily bars.
/// Symbol format: "<ticker>:<code>|<xid>" e.g. "7203:TYO|27182".
public final class FTProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.ft
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 3, minInterval: 0.2)
    private let names = NameCache()

    public init() {}

    /// Company name behind a symbol ("AXL1:FRA|xid" is Axfood), looked up once per symbol; the price series does not carry it.
    func instrumentName(_ symbol: String, env: ProviderEnvironment) async -> String? {
        if let n = await names.get(symbol) { return n }
        guard let xid = try? xid(symbol), let ticker = symbol.split(separator: "|").first.map(String.init),
              let hits = try? await rawSearch(ticker, env: env), let hit = hits.first(where: { $0.xid == xid }) else { return nil }
        await names.put(symbol, hit.name)
        return hit.name
    }

    struct Hit {
        var symbol: String
        var xid: String
        var name: String
        var assetClass: String
    }

    func rawSearch(_ query: String, env: ProviderEnvironment) async throws -> [Hit] {
        let url = URL.make("https://markets.ft.com/data/searchapi/searchsecurities", [("query", query)])
        let obj = try await gate.run { try await env.http.json(url) }
        guard let root = obj as? [String: Any], let list = root.dict("data")?["security"] as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let sym = s.str("symbol"), let xid = s.str("xid") else { return nil }
            return Hit(symbol: sym, xid: xid, name: s.str("name") ?? sym, assetClass: s.str("assetClass") ?? "")
        }
    }

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let hits = try await rawSearch(query, env: env)
        var out: [SearchCandidate] = []
        for h in hits where ["Equities", "ETFs", "Funds"].contains(h.assetClass) {
            let parts = h.symbol.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { continue }
            let ex = env.catalog.match(.ft, code: parts[1])
            let cur = parts.count >= 3 ? CurrencyNormalizer.normalize(parts[2]).code : nil
            out.append(SearchCandidate(provider: id, name: h.name, isin: Lenient.isISIN(query) ? query.uppercased() : nil,
                                       ticker: parts[0], symbol: "\(parts[0]):\(parts[1])|\(h.xid)", exchangeID: ex?.id,
                                       exchangeLabel: parts[1], currency: cur ?? ex?.currency,
                                       assetType: h.assetClass == "ETFs" ? .etf : h.assetClass == "Funds" ? .fund : .stock))
        }
        return out
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        let codes = exchange.matchCodes(.ft)
        guard !codes.isEmpty else { throw ProviderError.unsupported(exchange.name) }
        let stored = ref.listing.symbol(.ft)
        if let s = stored, s.contains("|") { return s }
        // The ISIN first: a ticker may belong to another venue and name another company here.
        if let s = try? await symbolByISIN(ref, exchange: exchange, env: env) { return s }
        var queries: [String] = []
        if let s = stored, !s.isEmpty { queries.append(s) }
        queries.append("\(ref.listing.ticker):\(codes[0])")
        queries.append(ref.name)
        for q in queries {
            guard let hits = try? await rawSearch(q, env: env) else { continue }
            let wantedTicker = (stored?.split(separator: ":").first.map(String.init) ?? ref.listing.ticker).uppercased()
            let onVenue = hits.filter { h in
                let p = h.symbol.split(separator: ":").map(String.init)
                return p.count >= 2 && codes.contains(p[1])
            }
            if let exact = onVenue.first(where: { $0.symbol.split(separator: ":").first.map(String.init)?.uppercased() == wantedTicker }),
               Lenient.sameCompany(exact.name, ref.name) != false {
                return Self.format(exact)
            }
            // Searching by ISIN or name: accept the venue match.
            if q == ref.isin || q == ref.name, let first = onVenue.first(where: { $0.assetClass == "Equities" || $0.assetClass == "ETFs" }) ?? onVenue.first {
                if q == ref.isin || Lenient.nameKey(first.name) == Lenient.nameKey(ref.name) { return Self.format(first) }
            }
        }
        throw ProviderError.notFound("\(ref.name) an \(exchange.name)")
    }

    public func symbolByISIN(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String? {
        guard let isin = ref.isin?.uppercased(), Lenient.isISIN(isin) else { return nil }
        let codes = exchange.matchCodes(.ft)
        guard !codes.isEmpty else { return nil }
        let onVenue = try await rawSearch(isin, env: env).filter { h in
            let p = h.symbol.split(separator: ":").map(String.init)
            return p.count >= 2 && codes.contains(p[1])
        }
        return (onVenue.first(where: { $0.assetClass == "Equities" || $0.assetClass == "ETFs" }) ?? onVenue.first).map(Self.format)
    }

    static func format(_ h: Hit) -> String {
        let p = h.symbol.split(separator: ":").map(String.init)
        return "\(p[0]):\(p.count > 1 ? p[1] : "")|\(h.xid)"
    }

    private func xid(_ symbol: String) throws -> String {
        guard let x = symbol.split(separator: "|").last, symbol.contains("|") else { throw ProviderError.parse("FT-Symbol \(symbol)") }
        return String(x)
    }

    func series(xid: String, days: Int, env: ProviderEnvironment) async throws -> (bars: [Bar], currency: String) {
        let body: [String: Any] = [
            "days": days, "dataNormalized": false, "dataPeriod": "Day", "dataInterval": 1, "realtime": false,
            "yFormat": "0.###", "timeServiceFormat": "JSON", "returnDateType": "ISO8601",
            "elements": [["Type": "price", "Symbol": xid, "OverlayIndicators": [], "Params": [:]] as [String: Any]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (respData, resp) = try await gate.run {
            try await env.http.post(URL(string: "https://markets.ft.com/data/chartapi/series")!, body: data, contentType: "application/json")
        }
        if resp.statusCode == 400 { throw ProviderError.notFound("FT xid \(xid)") }
        try HTTPClient.check(resp, respData)
        guard let root = try HTTPClient.parse(respData) as? [String: Any],
              let dates = root["Dates"] as? [String],
              let el = (root["Elements"] as? [[String: Any]])?.first,
              let comps = el["ComponentSeries"] as? [[String: Any]] else { throw ProviderError.parse("FT series") }
        let norm = CurrencyNormalizer.normalize(el.str("Currency"))
        func values(_ type: String) -> [Any]? { comps.first(where: { $0.str("Type") == type })?["Values"] as? [Any] }
        guard let closes = values("Close") else { throw ProviderError.parse("FT close") }
        let opens = values("Open"), highs = values("High"), lows = values("Low")
        var bars: [Bar] = []
        for i in 0..<min(dates.count, closes.count) {
            guard let day = DayKey(iso: dates[i]), let c = Lenient.double(any: closes[i]), c > 0 else { continue }
            func v(_ a: [Any]?) -> Double? { a.flatMap { i < $0.count ? Lenient.double(any: $0[i]) : nil }.map { $0 * norm.factor } }
            bars.append(Bar(day: day, close: c * norm.factor, open: v(opens), high: v(highs), low: v(lows)))
        }
        return (bars, norm.code)
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let (bars, cur) = try await series(xid: try xid(symbol), days: 12, env: env)
        guard let last = bars.last else { throw ProviderError.notFound(symbol) }
        let prev = bars.count >= 2 ? bars[bars.count - 2].close : nil
        return Quote(price: last.close, time: ProviderUtil.closeTime(last.day, exchange), previousClose: prev, currency: cur, source: id,
                     instrumentName: await instrumentName(symbol, env: env))
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let days = max(10, from.days(to: DayKey.today()) + 5)
        let (bars, cur) = try await series(xid: try xid(symbol), days: days, env: env)
        if bars.isEmpty { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: bars, currency: cur, source: id, instrumentName: await instrumentName(symbol, env: env))
    }
}

actor NameCache {
    private var map: [String: String] = [:]
    func get(_ k: String) -> String? { map[k] }
    func put(_ k: String, _ v: String) { map[k] = v }
}
