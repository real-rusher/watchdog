import Foundation

public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let search = ProviderCapabilities(rawValue: 1)
    public static let quote = ProviderCapabilities(rawValue: 2)
    public static let history = ProviderCapabilities(rawValue: 4)
    public static let all: ProviderCapabilities = [.search, .quote, .history]
}

/// What a provider needs to know about the security it should look up.
public struct SecurityRef: Sendable, Hashable {
    public var name: String
    public var isin: String?
    public var wkn: String?
    public var listing: Listing
    public var assetType: AssetType

    public init(name: String, isin: String?, wkn: String?, listing: Listing, assetType: AssetType) {
        self.name = name
        self.isin = isin
        self.wkn = wkn
        self.listing = listing
        self.assetType = assetType
    }

    public init(_ p: Position) {
        self.init(name: p.name, isin: p.isin, wkn: p.wkn, listing: p.listing, assetType: p.assetType)
    }
}

/// One search hit: a security at a venue, as one provider sees it.
public struct SearchCandidate: Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(symbol)" }
    public var provider: ProviderID
    public var name: String
    public var isin: String?
    public var wkn: String?
    public var ticker: String
    public var symbol: String
    public var exchangeID: ExchangeID?
    public var exchangeLabel: String
    public var currency: String?
    public var assetType: AssetType
    /// Last price if the search response already contains it.
    public var lastPrice: Double?

    public init(provider: ProviderID, name: String, isin: String? = nil, wkn: String? = nil, ticker: String, symbol: String,
                exchangeID: ExchangeID?, exchangeLabel: String, currency: String? = nil, assetType: AssetType = .stock, lastPrice: Double? = nil) {
        self.provider = provider
        self.name = name
        self.isin = isin
        self.wkn = wkn
        self.ticker = ticker
        self.symbol = symbol
        self.exchangeID = exchangeID
        self.exchangeLabel = exchangeLabel
        self.currency = currency
        self.assetType = assetType
        self.lastPrice = lastPrice
    }
}

public struct ProviderEnvironment: Sendable {
    public var http: HTTPClient
    public var keys: [ProviderID: String]
    public var catalog: ExchangeCatalog

    public init(http: HTTPClient, keys: [ProviderID: String], catalog: ExchangeCatalog) {
        self.http = http
        self.keys = keys
        self.catalog = catalog
    }

    public func key(_ p: ProviderID) throws -> String {
        guard let k = keys[p]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { throw ProviderError.missingKey }
        return k
    }
}

public protocol MarketDataProvider: AnyObject, Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }
    var gate: RequestGate { get }

    func supports(_ exchange: Exchange) -> Bool
    func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate]
    /// Provider specific symbol for a security at a venue. May perform a lookup.
    func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String
    func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote
    func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult
}

public extension MarketDataProvider {
    func supports(_ exchange: Exchange) -> Bool { exchange.supports(id) }

    func search(_ query: String, env: ProviderEnvironment) async throws -> [SearchCandidate] {
        throw ProviderError.unsupported("Suche")
    }

    func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        throw ProviderError.unsupported("Kurs")
    }

    func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        throw ProviderError.unsupported("Historie")
    }
}

/// Helpers shared by the providers.
enum ProviderUtil {
    /// Yahoo style ticker: share classes use "-" ("ERIC-B", "BRK-B").
    static func yahooTicker(_ t: String) -> String {
        t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    static func assetType(fromYahoo t: String?) -> AssetType {
        switch t?.uppercased() {
        case "ETF": return .etf
        case "MUTUALFUND": return .fund
        case "CRYPTOCURRENCY": return .crypto
        case "EQUITY": return .stock
        default: return .other
        }
    }

    static func assetType(fromText t: String?) -> AssetType {
        let s = (t ?? "").lowercased()
        if s.contains("etf") || s.contains("etp") { return .etf }
        if s.contains("fund") || s.contains("fonds") { return .fund }
        if s.contains("crypto") || s.contains("krypto") || s.contains("digital currency") { return .crypto }
        if s.contains("stock") || s.contains("equit") || s.contains("aktie") || s.contains("share") || s.contains("common") { return .stock }
        return .other
    }

    /// Time of the session close on `day` at `exchange` (used when a provider only reports dates).
    static func closeTime(_ day: DayKey, _ exchange: Exchange) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchange.tz
        let mins = exchange.kind == .crypto ? 0 : exchange.closes
        let comps = DateComponents(year: day.year, month: day.month, day: day.day, hour: min(23, mins / 60), minute: mins % 60)
        let d = cal.date(from: comps) ?? day.date
        // A bar of a session still running has no exact time; free sources lag about 15 minutes.
        return d > Date() ? Date().addingTimeInterval(-15 * 60) : d
    }

    static func unixDate(_ t: Double) -> Date {
        Date(timeIntervalSince1970: t > 10_000_000_000 ? t / 1000 : t)
    }
}
