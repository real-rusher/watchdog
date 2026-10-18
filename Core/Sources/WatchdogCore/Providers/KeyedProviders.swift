import Foundation

// MARK: - EODHD

/// eodhd.com. Symbol "<CODE>.<EXCHANGE>" e.g. "SAP.XETRA".
public final class EODHDProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.eodhd
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 3, minInterval: 0.1)

    public init() {}

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let key = try env.key(id)
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        let url = URL.make("https://eodhd.com/api/search/\(q)", [("api_token", key), ("fmt", "json"), ("limit", "30")])
        guard let list = try await gate.run({ try await env.http.json(url) }) as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let code = r.str("Code"), let ex = r.str("Exchange") else { return nil }
            let venue = env.catalog.match(.eodhd, code: ex)
            return SearchCandidate(provider: id, name: r.str("Name") ?? code, isin: r.str("ISIN"), ticker: code, symbol: "\(code).\(ex)",
                                   exchangeID: venue?.id, exchangeLabel: ex, currency: r.str("Currency").map { CurrencyNormalizer.normalize($0).code },
                                   assetType: ProviderUtil.assetType(fromText: r.str("Type")), lastPrice: r.num("previousClose"))
        }
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.eodhd), !s.isEmpty { return s }
        guard let code = exchange.code(.eodhd) else { throw ProviderError.unsupported(exchange.name) }
        return ProviderUtil.yahooTicker(ref.listing.ticker) + "." + code
    }

    /// EODHD reports London prices in pence.
    private func currency(_ exchange: Exchange) -> CurrencyNormalizer.Result {
        exchange.id == "XLON" ? CurrencyNormalizer.normalize("GBX") : CurrencyNormalizer.normalize(exchange.currency)
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let key = try env.key(id)
        let url = URL.make("https://eodhd.com/api/real-time/\(symbol)", [("api_token", key), ("fmt", "json")])
        guard let r = try await gate.run({ try await env.http.json(url) }) as? [String: Any], let close = r.num("close"), close > 0 else {
            throw ProviderError.notFound(symbol)
        }
        let n = currency(exchange)
        let t = r.num("timestamp").map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Quote(price: close * n.factor, time: t, previousClose: r.num("previousClose").map { $0 * n.factor }, currency: n.code, source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let key = try env.key(id)
        let url = URL.make("https://eodhd.com/api/eod/\(symbol)", [("api_token", key), ("fmt", "json"), ("from", from.iso), ("period", "d")])
        guard let list = try await gate.run({ try await env.http.json(url) }) as? [[String: Any]] else { throw ProviderError.parse("eodhd eod") }
        let n = currency(exchange)
        let bars: [Bar] = list.compactMap { r in
            guard let d = r.str("date").flatMap(DayKey.init(iso:)), let c = r.num("close"), c > 0 else { return nil }
            return Bar(day: d, close: c * n.factor, open: r.num("open").map { $0 * n.factor }, high: r.num("high").map { $0 * n.factor },
                       low: r.num("low").map { $0 * n.factor }, volume: r.num("volume"))
        }
        if bars.isEmpty { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: bars, currency: n.code, source: id)
    }
}

// MARK: - Twelve Data

/// twelvedata.com. Symbol "<symbol>|<mic>" e.g. "SAP|XETR". Search works without a key.
public final class TwelveDataProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.twelvedata
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 1, minInterval: 8.0) // free tier: 8 credits per minute

    public init() {}

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let url = URL.make("https://api.twelvedata.com/symbol_search", [("symbol", query), ("outputsize", "30")])
        guard let root = try await env.http.json(url) as? [String: Any], let data = root["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { r in
            guard let sym = r.str("symbol"), let mic = r.str("mic_code") else { return nil }
            let venue = env.catalog.match(.twelvedata, code: mic)
            return SearchCandidate(provider: id, name: r.str("instrument_name") ?? sym, isin: Lenient.isISIN(query) ? query.uppercased() : nil,
                                   ticker: sym, symbol: "\(sym)|\(mic)", exchangeID: venue?.id, exchangeLabel: r.str("exchange") ?? mic,
                                   currency: r.str("currency").map { CurrencyNormalizer.normalize($0).code },
                                   assetType: ProviderUtil.assetType(fromText: r.str("instrument_type")))
        }
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.twelvedata), s.contains("|") { return s }
        guard let mic = exchange.code(.twelvedata) else { throw ProviderError.unsupported(exchange.name) }
        return "\(ref.listing.ticker)|\(mic)"
    }

    private func parts(_ s: String) -> (String, String) {
        let p = s.split(separator: "|").map(String.init)
        return (p.first ?? s, p.count > 1 ? p[1] : "")
    }

    private func checkError(_ r: [String: Any]) throws {
        guard r.str("status") == "error" else { return }
        let code = Int(r.num("code") ?? 0)
        let msg = r.str("message") ?? "Fehler"
        if code == 429 { throw ProviderError.throttled(msg) }
        if code == 401 { throw ProviderError.missingKey }
        if code == 403 { throw ProviderError.notInPlan(msg) }
        throw ProviderError.notFound(msg)
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let key = try env.key(id)
        let (s, mic) = parts(symbol)
        let url = URL.make("https://api.twelvedata.com/quote", [("symbol", s), ("mic_code", mic), ("apikey", key)])
        guard let r = try await gate.run({ try await env.http.json(url) }) as? [String: Any] else { throw ProviderError.parse("twelvedata quote") }
        try checkError(r)
        let n = CurrencyNormalizer.normalize(r.str("currency"))
        guard let close = r.num("close"), close > 0 else { throw ProviderError.notFound(symbol) }
        let t = (r.num("last_quote_at") ?? r.num("timestamp")).map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Quote(price: close * n.factor, time: t, previousClose: r.num("previous_close").map { $0 * n.factor }, currency: n.code, source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let key = try env.key(id)
        let (s, mic) = parts(symbol)
        let url = URL.make("https://api.twelvedata.com/time_series", [
            ("symbol", s), ("mic_code", mic), ("interval", "1day"), ("start_date", from.iso), ("outputsize", "5000"), ("order", "asc"), ("apikey", key),
        ])
        guard let r = try await gate.run({ try await env.http.json(url) }) as? [String: Any] else { throw ProviderError.parse("twelvedata series") }
        try checkError(r)
        let n = CurrencyNormalizer.normalize(r.dict("meta")?.str("currency"))
        let values = (r["values"] as? [[String: Any]]) ?? []
        let bars: [Bar] = values.compactMap { v in
            guard let d = v.str("datetime").flatMap(DayKey.init(iso:)), let c = v.num("close"), c > 0 else { return nil }
            return Bar(day: d, close: c * n.factor, open: v.num("open").map { $0 * n.factor }, high: v.num("high").map { $0 * n.factor },
                       low: v.num("low").map { $0 * n.factor }, volume: v.num("volume"))
        }
        if bars.isEmpty { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: bars, currency: n.code, source: id)
    }
}

// MARK: - Alpha Vantage

/// alphavantage.co. Symbol e.g. "IBM", "TSCO.LON", "SAP.DEX".
public final class AlphaVantageProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.alphavantage
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 1, minInterval: 1.5)

    public init() {}

    private func call(_ params: [(String, String)], env: ProviderEnvironment) async throws -> [String: Any] {
        let key = try env.key(id)
        let url = URL.make("https://www.alphavantage.co/query", params + [("apikey", key)])
        guard let r = try await gate.run({ try await env.http.json(url) }) as? [String: Any] else { throw ProviderError.parse("alphavantage") }
        if let note = r.str("Note") ?? r.str("Information") {
            if note.lowercased().contains("premium") { throw ProviderError.notInPlan(note) }
            throw ProviderError.throttled(note)
        }
        if let err = r.str("Error Message") { throw ProviderError.notFound(err) }
        return r
    }

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let r = try await call([("function", "SYMBOL_SEARCH"), ("keywords", query)], env: env)
        let list = (r["bestMatches"] as? [[String: Any]]) ?? []
        return list.compactMap { m in
            guard let sym = m.str("1. symbol") else { return nil }
            var ticker = sym
            var venue: Exchange?
            if let dot = sym.lastIndex(of: ".") {
                let suffix = String(sym[sym.index(after: dot)...])
                venue = env.catalog.match(.alphavantage, code: suffix)
                if venue != nil { ticker = String(sym[..<dot]) }
            } else if m.str("4. region") == "United States" {
                venue = env.catalog["XNYS"]
            }
            return SearchCandidate(provider: id, name: m.str("2. name") ?? sym, ticker: ticker, symbol: sym, exchangeID: venue?.id,
                                   exchangeLabel: m.str("4. region") ?? "", currency: m.str("8. currency").map { CurrencyNormalizer.normalize($0).code },
                                   assetType: ProviderUtil.assetType(fromText: m.str("3. type")))
        }
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.alphavantage), !s.isEmpty { return s }
        guard let code = exchange.code(.alphavantage) else { throw ProviderError.unsupported(exchange.name) }
        let t = ref.listing.ticker.replacingOccurrences(of: " ", with: "-")
        return code.isEmpty ? t : "\(t).\(code)"
    }

    private func currency(_ exchange: Exchange) -> CurrencyNormalizer.Result {
        exchange.id == "XLON" ? CurrencyNormalizer.normalize("GBX") : CurrencyNormalizer.normalize(exchange.currency)
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let r = try await call([("function", "GLOBAL_QUOTE"), ("symbol", symbol)], env: env)
        guard let q = r.dict("Global Quote"), let p = q.num("05. price"), p > 0 else { throw ProviderError.notFound(symbol) }
        let n = currency(exchange)
        let day = q.str("07. latest trading day").flatMap(DayKey.init(iso:)) ?? DayKey.today()
        return Quote(price: p * n.factor, time: ProviderUtil.closeTime(day, exchange), previousClose: q.num("08. previous close").map { $0 * n.factor },
                     currency: n.code, source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        var r: [String: Any]
        do {
            r = try await call([("function", "TIME_SERIES_DAILY"), ("symbol", symbol), ("outputsize", "full")], env: env)
        } catch ProviderError.notInPlan {
            r = try await call([("function", "TIME_SERIES_DAILY"), ("symbol", symbol), ("outputsize", "compact")], env: env)
        }
        guard let ts = r.dict("Time Series (Daily)") else { throw ProviderError.notFound(symbol) }
        let n = currency(exchange)
        let bars: [Bar] = ts.compactMap { (k, v) in
            guard let d = DayKey(iso: k), d >= from, let o = v as? [String: Any], let c = o.num("4. close"), c > 0 else { return nil }
            return Bar(day: d, close: c * n.factor, open: o.num("1. open").map { $0 * n.factor }, high: o.num("2. high").map { $0 * n.factor },
                       low: o.num("3. low").map { $0 * n.factor }, volume: o.num("5. volume"))
        }
        if bars.isEmpty { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: bars, currency: n.code, source: id)
    }
}

// MARK: - Finnhub

/// finnhub.io. Symbols like Yahoo ("AAPL", "SAP.DE"). Free tier: quotes for US venues.
public final class FinnhubProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.finnhub
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 2, minInterval: 1.1) // 60 calls/minute

    public init() {}

    private func get(_ path: String, _ params: [(String, String)], env: ProviderEnvironment) async throws -> Any {
        let key = try env.key(id)
        let url = URL.make("https://finnhub.io/api/v1/\(path)", params + [("token", key)])
        do {
            return try await gate.run { try await env.http.json(url) }
        } catch ProviderError.http(403, let m) {
            throw ProviderError.notInPlan(m)
        } catch ProviderError.http(401, _) {
            throw ProviderError.missingKey
        }
    }

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        guard let r = try await get("search", [("q", query)], env: env) as? [String: Any], let list = r["result"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let sym = m.str("symbol") else { return nil }
            var venue: Exchange?
            var ticker = sym
            if let dot = sym.lastIndex(of: ".") {
                let suffix = String(sym[dot...])
                venue = env.catalog.all.first { $0.code(.finnhub) == suffix && $0.isActive } ?? env.catalog.all.first { $0.code(.finnhub) == suffix }
                if venue != nil { ticker = String(sym[..<dot]) }
            }
            return SearchCandidate(provider: id, name: m.str("description") ?? sym, ticker: ticker, symbol: sym, exchangeID: venue?.id,
                                   exchangeLabel: venue?.name ?? "USA", assetType: ProviderUtil.assetType(fromText: m.str("type")))
        }
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.finnhub), !s.isEmpty { return s }
        guard let suffix = exchange.code(.finnhub) else { throw ProviderError.unsupported(exchange.name) }
        return ProviderUtil.yahooTicker(ref.listing.ticker).replacingOccurrences(of: "-", with: ".") + suffix
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        guard let r = try await get("quote", [("symbol", symbol)], env: env) as? [String: Any], let c = r.num("c"), c > 0 else {
            throw ProviderError.notFound(symbol)
        }
        let t = r.num("t").map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Quote(price: c, time: t, previousClose: r.num("pc"), currency: exchange.currency, source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let p = [("symbol", symbol), ("resolution", "D"), ("from", String(Int(from.date.timeIntervalSince1970))), ("to", String(Int(Date().timeIntervalSince1970)))]
        guard let r = try await get("stock/candle", p, env: env) as? [String: Any] else { throw ProviderError.parse("finnhub candle") }
        if r.str("s") != "ok" { throw ProviderError.notFound(symbol) }
        let t = (r["t"] as? [Any]) ?? [], c = (r["c"] as? [Any]) ?? []
        var bars: [Bar] = []
        for i in 0..<min(t.count, c.count) {
            guard let ts = Lenient.double(any: t[i]), let close = Lenient.double(any: c[i]) else { continue }
            bars.append(Bar(day: DayKey(date: Date(timeIntervalSince1970: ts), timeZone: exchange.tz), close: close))
        }
        return HistoryResult(bars: bars, currency: exchange.currency, source: id)
    }
}
