import Foundation

public enum AssetType: String, Codable, CaseIterable, Sendable {
    case stock, etf, fund, crypto, other

    public var label: String {
        switch self {
        case .stock: return "Aktie"
        case .etf: return "ETF"
        case .fund: return "Fonds"
        case .crypto: return "Krypto"
        case .other: return "Sonstiges"
        }
    }
}

/// Where a security is quoted and how each provider calls it.
public struct Listing: Codable, Hashable, Sendable {
    public var exchangeID: ExchangeID
    /// Local ticker as shown to the user (e.g. "7203", "CCO", "BTCUSD").
    public var ticker: String
    /// Trading currency if it differs from the venue default (e.g. a USD line at SIX).
    public var currency: String?
    /// Provider specific symbols, keyed by `ProviderID.rawValue`.
    public var symbols: [String: String]
    /// Forces a provider for this listing (nil = automatic).
    public var preferredProvider: ProviderID?

    public init(exchangeID: ExchangeID, ticker: String, currency: String? = nil, symbols: [String: String] = [:], preferredProvider: ProviderID? = nil) {
        self.exchangeID = exchangeID
        self.ticker = ticker
        self.currency = currency
        self.symbols = symbols
        self.preferredProvider = preferredProvider
    }

    /// Stable key for caches.
    public var key: String { "\(exchangeID):\(ticker.uppercased())" }

    public func symbol(_ p: ProviderID) -> String? { symbols[p.rawValue] }
}

/// One purchase.
public struct Lot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var day: DayKey
    public var quantity: Double
    /// What was paid in total, in EUR (fees included if the user wants them included).
    public var totalCostEUR: Double
    public var note: String

    public init(id: UUID = UUID(), day: DayKey, quantity: Double, totalCostEUR: Double, note: String = "") {
        self.id = id
        self.day = day
        self.quantity = quantity
        self.totalCostEUR = totalCostEUR
        self.note = note
    }

    public var pricePerUnitEUR: Double { quantity > 0 ? totalCostEUR / quantity : 0 }
}

public struct Bank: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortIndex: Int
    public init(id: UUID = UUID(), name: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}

public struct Theme: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortIndex: Int
    /// Optional colour as hex string ("#C8A200").
    public var color: String?
    public init(id: UUID = UUID(), name: String, sortIndex: Int = 0, color: String? = nil) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.color = color
    }
}

public struct Position: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isin: String?
    public var wkn: String?
    public var assetType: AssetType
    public var listing: Listing
    public var lots: [Lot]
    public var bankID: UUID?
    public var themeID: UUID?
    public var note: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, isin: String? = nil, wkn: String? = nil, assetType: AssetType = .stock,
                listing: Listing, lots: [Lot] = [], bankID: UUID? = nil, themeID: UUID? = nil, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isin = isin
        self.wkn = wkn
        self.assetType = assetType
        self.listing = listing
        self.lots = lots
        self.bankID = bankID
        self.themeID = themeID
        self.note = note
        self.createdAt = createdAt
    }

    /// Positions without purchases are pure watch list entries.
    public var isWatchOnly: Bool { lots.isEmpty || quantity <= 0 }
    public var quantity: Double { lots.reduce(0) { $0 + $1.quantity } }
    public var totalCostEUR: Double { lots.reduce(0) { $0 + $1.totalCostEUR } }
    public var averagePriceEUR: Double? { quantity > 0 ? totalCostEUR / quantity : nil }
    public var firstPurchase: DayKey? { lots.map(\.day).min() }
}

/// How the main table is grouped.
public enum Grouping: String, Codable, CaseIterable, Sendable {
    case bank, theme, none

    public var label: String {
        switch self {
        case .bank: return "Nach Bank"
        case .theme: return "Nach Thema"
        case .none: return "Eine Liste"
        }
    }
}
