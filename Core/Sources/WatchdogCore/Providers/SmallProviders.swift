import Foundation

// MARK: - Lang & Schwarz (LS Exchange)

/// ls-tc.de JSON endpoints. Symbol = instrument id (e.g. "34313"). Prices are mid quotes.
public final class LSTCProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.lstc
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 2, minInterval: 0.25)

    public init() {}

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let url = URL.make("https://www.ls-tc.de/_rpc/json/.lstc/instrument/search/main", [("q", query), ("localeId", "2")])
        let obj = try await gate.run { try await env.http.json(url) }
        guard let list = obj as? [[String: Any]] else { return [] }
        let venue = env.catalog.all.first { $0.supports(.lstc) && $0.isActive } ?? env.catalog.all.first { $0.supports(.lstc) }
        return list.compactMap { r in
            guard let idv = r.str("instrumentId") ?? r.str("id") else { return nil }
            let cat = r.str("categoryName") ?? ""
            return SearchCandidate(provider: id, name: r.str("displayname") ?? query, isin: r.str("isin"), wkn: r.str("wkn"),
                                   ticker: r.str("wkn") ?? r.str("isin") ?? idv, symbol: idv, exchangeID: venue?.id,
                                   exchangeLabel: "LS Exchange", currency: "EUR", assetType: ProviderUtil.assetType(fromText: cat))
        }
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.lstc), !s.isEmpty { return s }
        guard exchange.supports(.lstc) else { throw ProviderError.unsupported(exchange.name) }
        for q in [ref.isin, ref.wkn].compactMap({ $0 }) {
            if let hit = try await search(q, env: env).first(where: { $0.isin == ref.isin || $0.wkn == ref.wkn }) { return hit.symbol }
        }
        throw ProviderError.notFound(ref.name)
    }

    private func chart(_ symbol: String, series: String, env: ProviderEnvironment) async throws -> [String: Any] {
        let url = URL.make("https://www.ls-tc.de/_rpc/json/instrument/chart/dataForInstrument", [
            ("container", "chart1"), ("instrumentId", symbol), ("marketId", "1"), ("quotetype", "mid"),
            ("series", series), ("type", "mini"), ("localeId", "2"),
        ])
        guard let root = try await gate.run({ try await env.http.json(url) }) as? [String: Any] else { throw ProviderError.parse("ls-tc") }
        return root
    }

    private static func points(_ root: [String: Any], _ series: String) -> [(Date, Double)] {
        guard let s = root.dict("series")?.dict(series), let data = s["data"] as? [[Any]] else { return [] }
        return data.compactMap { p in
            guard p.count >= 2, let t = Lenient.double(any: p[0]), let v = Lenient.double(any: p[1]), v > 0 else { return nil }
            return (ProviderUtil.unixDate(t), v)
        }
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let root = try await chart(symbol, series: "intraday", env: env)
        let pts = Self.points(root, "intraday")
        let prev = (root.dict("info")?["plotlines"] as? [[String: Any]])?.first(where: { $0.str("id") == "previousDay" })?.num("value")
        guard let last = pts.last else {
            if let p = prev { return Quote(price: p, time: ProviderUtil.closeTime(exchange.lastCompletedSession(), exchange), previousClose: nil, currency: "EUR", source: id) }
            throw ProviderError.notFound(symbol)
        }
        return Quote(price: last.1, time: last.0, previousClose: prev, currency: "EUR", source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let root = try await chart(symbol, series: "history", env: env)
        let bars = Self.points(root, "history").map { Bar(day: DayKey(date: $0.0, timeZone: .berlin), close: $0.1) }.filter { $0.day >= from }
        if bars.isEmpty { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: bars, currency: "EUR", source: id)
    }
}

// MARK: - Tradegate

/// tradegate.de refresh endpoint: live price by ISIN, no history.
public final class TradegateProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.tradegate
    public let capabilities: ProviderCapabilities = [.quote]
    public let gate = RequestGate(maxConcurrent: 2, minInterval: 0.3)

    public init() {}

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        guard exchange.supports(.tradegate) else { throw ProviderError.unsupported(exchange.name) }
        if let s = ref.listing.symbol(.tradegate), Lenient.isISIN(s) { return s }
        guard let isin = ref.isin, Lenient.isISIN(isin) else { throw ProviderError.notFound("ISIN fehlt") }
        return isin.uppercased()
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let url = URL.make("https://www.tradegate.de/refresh.php", [("isin", symbol)])
        guard let root = try await gate.run({ try await env.http.json(url) }) as? [String: Any] else { throw ProviderError.parse("tradegate") }
        let last = root.num("last") ?? 0
        let bid = root.num("bid"), ask = root.num("ask")
        var price = last
        if price <= 0, let b = bid, let a = ask, b > 0, a > 0 { price = (a + b) / 2 }
        guard price > 0 else { throw ProviderError.notFound(symbol) }
        let time = exchange.isOpen() ? Date() : ProviderUtil.closeTime(exchange.lastCompletedSession(), exchange)
        return Quote(price: price, time: time, previousClose: root.num("close"), currency: "EUR", source: id)
    }
}

// MARK: - Bitfinex

/// Official public Bitfinex API v2. Symbol e.g. "tBTCUSD" or "tAVAX:USD".
public final class BitfinexProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.bitfinex
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 2, minInterval: 0.4)
    private let fiat: Set<String> = ["USD", "EUR", "GBP", "JPY", "UST", "CHF"]
    private let names: [String: String] = [
        "bitcoin": "BTC", "ethereum": "ETH", "ether": "ETH", "solana": "SOL", "ripple": "XRP", "xrp": "XRP", "cardano": "ADA",
        "dogecoin": "DOGE", "litecoin": "LTC", "polkadot": "DOT", "tether": "UST", "chainlink": "LINK", "avalanche": "AVAX",
        "tron": "TRX", "stellar": "XLM", "monero": "XMR", "uniswap": "UNI", "aave": "AAVE", "gold": "XAUT", "tether gold": "XAUT",
    ]

    public init() {}

    static func split(_ pair: String) -> (String, String) {
        if let i = pair.firstIndex(of: ":") { return (String(pair[..<i]), String(pair[pair.index(after: i)...])) }
        guard pair.count > 3 else { return (pair, "USD") }
        return (String(pair.prefix(pair.count - 3)), String(pair.suffix(3)))
    }

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let wanted = (names[q.lowercased()] ?? q).uppercased().replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "-", with: "")
        guard wanted.count >= 2 else { return [] }
        let url = URL(string: "https://api-pub.bitfinex.com/v2/conf/pub:list:pair:exchange")!
        guard let root = try await gate.run({ try await env.http.json(url) }) as? [[Any]], let pairs = root.first as? [String] else { return [] }
        let venue = env.catalog.all.first { $0.kind == .crypto && $0.supports(.bitfinex) }
        var out: [SearchCandidate] = []
        for p in pairs {
            let (base, quote) = Self.split(p)
            guard fiat.contains(quote) else { continue }
            let joined = base + quote
            guard base == wanted || joined == wanted || (wanted.count >= 3 && base.hasPrefix(wanted)) else { continue }
            let cur = CurrencyNormalizer.normalize(quote).code
            out.append(SearchCandidate(provider: id, name: "\(base) in \(quote == "UST" ? "USDt" : quote)", ticker: joined.replacingOccurrences(of: ":", with: ""),
                                       symbol: "t" + p, exchangeID: venue?.id, exchangeLabel: "Bitfinex", currency: cur, assetType: .crypto))
        }
        return out.sorted { a, b in
            // USD and EUR pairs first.
            func rank(_ c: SearchCandidate) -> Int { c.symbol.hasSuffix("USD") ? 0 : c.symbol.hasSuffix("EUR") ? 1 : 2 }
            return rank(a) < rank(b)
        }
    }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        guard exchange.supports(.bitfinex) else { throw ProviderError.unsupported(exchange.name) }
        if let s = ref.listing.symbol(.bitfinex), s.hasPrefix("t") { return s }
        return "t" + ref.listing.ticker.uppercased()
    }

    private func currency(_ symbol: String) -> String {
        CurrencyNormalizer.normalize(Self.split(String(symbol.dropFirst())).1).code
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let url = URL(string: "https://api-pub.bitfinex.com/v2/ticker/\(symbol)")!
        guard let arr = try await gate.run({ try await env.http.json(url) }) as? [Any], arr.count >= 7,
              let last = Lenient.double(any: arr[6]) else { throw ProviderError.notFound(symbol) }
        let change = Lenient.double(any: arr[4]) ?? 0
        return Quote(price: last, time: Date(), previousClose: last - change, currency: currency(symbol), source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let start = Int(from.date.timeIntervalSince1970 * 1000) - 86_400_000
        let url = URL.make("https://api-pub.bitfinex.com/v2/candles/trade:1D:\(symbol)/hist", [("start", String(start)), ("limit", "10000"), ("sort", "1")])
        guard let arr = try await gate.run({ try await env.http.json(url) }) as? [[Any]] else { throw ProviderError.parse("bitfinex candles") }
        let bars: [Bar] = arr.compactMap { c in
            guard c.count >= 6, let t = Lenient.double(any: c[0]), let close = Lenient.double(any: c[2]), close > 0 else { return nil }
            return Bar(day: DayKey(date: ProviderUtil.unixDate(t), timeZone: .utc), close: close, open: Lenient.double(any: c[1]),
                       high: Lenient.double(any: c[3]), low: Lenient.double(any: c[4]), volume: Lenient.double(any: c[5]))
        }
        if bars.isEmpty { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: bars, currency: currency(symbol), source: id)
    }
}
