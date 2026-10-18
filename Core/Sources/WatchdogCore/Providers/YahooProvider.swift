import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Yahoo Finance (unofficial endpoints). Uses cookie + crumb when Yahoo insists on it,
/// including the EU consent step.
public final class YahooProvider: MarketDataProvider, @unchecked Sendable {
    public let id = ProviderID.yahoo
    public let capabilities: ProviderCapabilities = .all
    public let gate = RequestGate(maxConcurrent: 2, minInterval: 0.35)
    private let auth = YahooAuth()

    public init() {}

    // MARK: Search

    public func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        let url = URL.make("https://query2.finance.yahoo.com/v1/finance/search", [
            ("q", query), ("quotesCount", "25"), ("newsCount", "0"), ("listsCount", "0"), ("enableFuzzyQuery", "false"),
        ])
        let obj = try await request(url, env: env)
        guard let root = obj as? [String: Any], let quotes = root["quotes"] as? [[String: Any]] else { return [] }
        var out: [SearchCandidate] = []
        for q in quotes {
            guard let symbol = q.str("symbol") else { continue }
            let type = q.str("quoteType")
            if let t = type, ["INDEX", "FUTURE", "OPTION", "CURRENCY"].contains(t) { continue }
            let exch = q.str("exchange")
            let venue = env.catalog.matchYahoo(symbol: symbol, exchangeCode: exch)
            var ticker = symbol
            if let suffix = venue?.code(.yahoo), !suffix.isEmpty, ticker.hasSuffix(suffix) { ticker.removeLast(suffix.count) }
            let name = q.str("longname") ?? q.str("shortname") ?? symbol
            out.append(SearchCandidate(provider: id, name: name, ticker: ticker, symbol: symbol, exchangeID: venue?.id,
                                       exchangeLabel: q.str("exchDisp") ?? exch ?? "", currency: nil,
                                       assetType: ProviderUtil.assetType(fromYahoo: type)))
        }
        return out
    }

    // MARK: Symbols

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        if let s = ref.listing.symbol(.yahoo), !s.isEmpty { return s }
        guard let suffix = exchange.code(.yahoo) else { throw ProviderError.unsupported(exchange.name) }
        return ProviderUtil.yahooTicker(ref.listing.ticker) + suffix
    }

    // MARK: Data

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        let url = URL.make("https://query1.finance.yahoo.com/v8/finance/chart/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)", [
            ("range", "5d"), ("interval", "1d"), ("includePrePost", "false"),
        ])
        let parsed = try parseChart(try await request(url, env: env), symbol: symbol)
        guard let price = parsed.price else { throw ProviderError.notFound(symbol) }
        let quoteDay = DayKey(date: parsed.time ?? Date(), timeZone: exchange.tz)
        let prev = parsed.bars.last(where: { $0.day < quoteDay })?.close ?? parsed.previousClose
        return Quote(price: price, time: parsed.time ?? Date(), previousClose: prev, currency: parsed.currency, source: id)
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        let p1 = Int(from.date.timeIntervalSince1970) - 86400
        let p2 = Int(Date().timeIntervalSince1970) + 86400
        let url = URL.make("https://query1.finance.yahoo.com/v8/finance/chart/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)", [
            ("period1", String(p1)), ("period2", String(p2)), ("interval", "1d"), ("includePrePost", "false"), ("events", "div,split"),
        ])
        let parsed = try parseChart(try await request(url, env: env), symbol: symbol)
        return HistoryResult(bars: parsed.bars, currency: parsed.currency, source: id)
    }

    struct ParsedChart {
        var bars: [Bar]
        var currency: String
        var price: Double?
        var time: Date?
        var previousClose: Double?
    }

    func parseChart(_ obj: Any, symbol: String) throws -> ParsedChart {
        guard let root = obj as? [String: Any], let chart = root.dict("chart") else { throw ProviderError.parse("chart") }
        if let err = chart.dict("error"), let desc = err.str("description") ?? err.str("code") {
            throw ProviderError.notFound("\(symbol): \(desc)")
        }
        guard let result = (chart["result"] as? [[String: Any]])?.first, let meta = result.dict("meta") else {
            throw ProviderError.notFound(symbol)
        }
        let norm = CurrencyNormalizer.normalize(meta.str("currency"))
        let offset = meta.num("gmtoffset") ?? 0
        var bars: [Bar] = []
        if let ts = result["timestamp"] as? [Any],
           let q = (result.dict("indicators")?["quote"] as? [[String: Any]])?.first,
           let closes = q["close"] as? [Any] {
            let opens = q["open"] as? [Any]
            let highs = q["high"] as? [Any]
            let lows = q["low"] as? [Any]
            let vols = q["volume"] as? [Any]
            for i in 0..<min(ts.count, closes.count) {
                guard let t = Lenient.double(any: ts[i]), let c = Lenient.double(any: closes[i]), c > 0 else { continue }
                let day = DayKey(date: Date(timeIntervalSince1970: t + offset), timeZone: .utc)
                func v(_ a: [Any]?) -> Double? { a.flatMap { i < $0.count ? Lenient.double(any: $0[i]) : nil }.map { $0 * norm.factor } }
                bars.append(Bar(day: day, close: c * norm.factor, open: v(opens), high: v(highs), low: v(lows),
                                volume: vols.flatMap { i < $0.count ? Lenient.double(any: $0[i]) : nil }))
            }
        }
        // Yahoo occasionally repeats the last day; keep the latest value per day.
        var dedup: [DayKey: Bar] = [:]
        for b in bars { dedup[b.day] = b }
        let price = meta.num("regularMarketPrice").map { $0 * norm.factor }
        let time = meta.num("regularMarketTime").map { Date(timeIntervalSince1970: $0) }
        let prev = (meta.num("previousClose") ?? meta.num("chartPreviousClose")).map { $0 * norm.factor }
        return ParsedChart(bars: dedup.values.sorted { $0.day < $1.day }, currency: norm.code, price: price, time: time, previousClose: prev)
    }

    // MARK: Transport with crumb handling

    private func request(_ url: URL, env: ProviderEnvironment) async throws -> Any {
        try await gate.run {
            if let crumb = await self.auth.crumb {
                return try await self.fetch(self.appending(crumb: crumb, to: url), env: env)
            }
            do {
                return try await self.fetch(url, env: env)
            } catch let e as ProviderError {
                switch e {
                case .throttled, .http(401, _), .http(403, _):
                    guard let crumb = try await self.auth.obtain(env.http) else { throw e }
                    return try await self.fetch(self.appending(crumb: crumb, to: url), env: env)
                default:
                    throw e
                }
            }
        }
    }

    private func fetch(_ url: URL, env: ProviderEnvironment) async throws -> Any {
        let (data, resp) = try await env.http.get(url, headers: ["Accept": "application/json,text/plain,*/*", "Referer": "https://finance.yahoo.com/"])
        if resp.statusCode == 404 {
            // Unknown symbols come back as 404 with a JSON body that names the problem.
            if let obj = try? HTTPClient.parse(data) { return obj }
        }
        try HTTPClient.check(resp, data)
        return try HTTPClient.parse(data)
    }

    private func appending(crumb: String, to url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "crumb" } + [URLQueryItem(name: "crumb", value: crumb)]
        return c.url!
    }
}

/// Holds Yahoo's crumb. Cookies live in the shared HTTP session.
actor YahooAuth {
    private(set) var crumb: String?
    private var lastAttempt = Date.distantPast

    func obtain(_ http: HTTPClient) async throws -> String? {
        if let c = crumb { return c }
        // Avoid hammering Yahoo when it refuses us.
        guard Date().timeIntervalSince(lastAttempt) > 60 else { return nil }
        lastAttempt = Date()

        _ = try? await http.get(URL(string: "https://fc.yahoo.com")!)
        if let c = try await fetchCrumb(http) { crumb = c; return c }

        // EU visitors first have to pass the consent page.
        try? await passConsent(http)
        if let c = try await fetchCrumb(http) { crumb = c; return c }
        return nil
    }

    func reset() { crumb = nil }

    private func fetchCrumb(_ http: HTTPClient) async throws -> String? {
        for host in ["query1", "query2"] {
            guard let (data, resp) = try? await http.get(URL(string: "https://\(host).finance.yahoo.com/v1/test/getcrumb")!) else { continue }
            if resp.statusCode == 200, let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, s.count < 40, !s.contains("<") {
                return s
            }
        }
        return nil
    }

    private func passConsent(_ http: HTTPClient) async throws {
        let (data, resp) = try await http.get(URL(string: "https://finance.yahoo.com/")!)
        guard let finalURL = resp.url, finalURL.host?.contains("consent") == true,
              let html = String(data: data, encoding: .utf8) else { return }
        func input(_ name: String) -> String? {
            let patterns = ["name=\"\(name)\" value=\"", "name='\(name)' value='"]
            for p in patterns {
                if let r = html.range(of: p) {
                    let rest = html[r.upperBound...]
                    if let end = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) { return String(rest[..<end]) }
                }
            }
            return nil
        }
        guard let csrf = input("csrfToken"), let session = input("sessionId") else { return }
        let fields: [(String, String)] = [
            ("csrfToken", csrf), ("sessionId", session), ("namespace", "yahoo"), ("agree", "agree"), ("agree", "agree"),
            ("consentUUID", "default"), ("originalDoneUrl", "https://finance.yahoo.com/"),
        ]
        let body = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.1)" }.joined(separator: "&")
        let target = URL(string: "https://consent.yahoo.com/v2/collectConsent?sessionId=\(session)")!
        _ = try? await http.post(target, body: Data(body.utf8), contentType: "application/x-www-form-urlencoded")
        _ = try? await http.get(URL(string: "https://guce.yahoo.com/copyConsent?sessionId=\(session)")!)
    }
}
