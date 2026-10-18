import Foundation

/// Which data source is asked first and in which order fallbacks are tried.
public struct SourcePreferences: Codable, Hashable, Sendable {
    /// Global order of providers. The first one that supports a venue is used, the rest are fallbacks.
    public var order: [ProviderID]
    /// Providers the user switched off.
    public var disabled: Set<ProviderID>
    /// Venue specific orders that override the global one.
    public var perExchange: [ExchangeID: [ProviderID]]
    /// Try the next provider automatically when one fails or throttles.
    public var autoFallback: Bool

    public init(order: [ProviderID] = ProviderID.defaultOrder, disabled: Set<ProviderID> = [], perExchange: [ExchangeID: [ProviderID]] = [:], autoFallback: Bool = true) {
        self.order = order
        self.disabled = disabled
        self.perExchange = perExchange
        self.autoFallback = autoFallback
    }

    /// Moves `p` to the front: the quick switch in the toolbar.
    public mutating func makePrimary(_ p: ProviderID) {
        order.removeAll { $0 == p }
        order.insert(p, at: 0)
        disabled.remove(p)
    }

    public var primary: ProviderID { order.first(where: { !disabled.contains($0) }) ?? .yahoo }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var order = (try? c.decode([ProviderID].self, forKey: .order)) ?? ProviderID.defaultOrder
        // Providers added in later versions are appended so they are never lost.
        for p in ProviderID.defaultOrder where !order.contains(p) { order.append(p) }
        self.order = order
        self.disabled = (try? c.decode(Set<ProviderID>.self, forKey: .disabled)) ?? []
        let raw = (try? c.decode([String: [ProviderID]].self, forKey: .perExchange)) ?? [:]
        self.perExchange = raw
        self.autoFallback = (try? c.decode(Bool.self, forKey: .autoFallback)) ?? true
    }

    enum CodingKeys: String, CodingKey { case order, disabled, perExchange, autoFallback }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(Array(disabled).sorted { $0.rawValue < $1.rawValue }, forKey: .disabled)
        try c.encode(perExchange, forKey: .perExchange)
        try c.encode(autoFallback, forKey: .autoFallback)
    }
}

public struct NotificationSettings: Codable, Hashable, Sendable {
    /// Banner on the Mac (and later on iPhone/iPad/Watch with the native apps).
    public var macEnabled: Bool
    /// Push to iPhone/Watch via the ntfy app.
    public var ntfyEnabled: Bool
    public var ntfyServer: String
    public var ntfyTopic: String
    /// Optional access token for protected ntfy servers.
    public var ntfyToken: String?

    public init(macEnabled: Bool = true, ntfyEnabled: Bool = false, ntfyServer: String = "https://ntfy.sh", ntfyTopic: String = NotificationSettings.randomTopic(), ntfyToken: String? = nil) {
        self.macEnabled = macEnabled
        self.ntfyEnabled = ntfyEnabled
        self.ntfyServer = ntfyServer
        self.ntfyTopic = ntfyTopic
        self.ntfyToken = ntfyToken
    }

    /// Hard to guess topic name; on ntfy.sh the topic name is the only protection.
    public static func randomTopic() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let tail = String((0..<16).map { _ in alphabet.randomElement()! })
        return "watchdog-\(tail)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macEnabled = c.value(.macEnabled, true)
        ntfyEnabled = c.value(.ntfyEnabled, false)
        ntfyServer = c.value(.ntfyServer, "https://ntfy.sh")
        ntfyTopic = c.value(.ntfyTopic, NotificationSettings.randomTopic())
        ntfyToken = c.value(.ntfyToken, nil as String?)
    }

    public var subscribeURL: URL? {
        URL(string: ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + ntfyTopic)
    }
}

/// Everything that belongs to the user's depot and is synced between devices (one JSON file).
public struct DepotFile: Codable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var positions: [Position]
    public var banks: [Bank]
    public var themes: [Theme]
    public var rules: RuleSet
    /// Modified built-in venues and custom venues.
    public var exchanges: [Exchange]
    public var sources: SourcePreferences
    public var notifications: NotificationSettings
    public var modifiedAt: Date

    public init(positions: [Position] = [], banks: [Bank] = [], themes: [Theme] = [], rules: RuleSet = RuleSet(),
                exchanges: [Exchange] = [], sources: SourcePreferences = SourcePreferences(),
                notifications: NotificationSettings = NotificationSettings(), modifiedAt: Date = Date()) {
        self.schemaVersion = DepotFile.currentSchema
        self.positions = positions
        self.banks = banks
        self.themes = themes
        self.rules = rules
        self.exchanges = exchanges
        self.sources = sources
        self.notifications = notifications
        self.modifiedAt = modifiedAt
    }

    /// Tolerant decoding: missing keys fall back to defaults so older or newer files still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        positions = try c.decodeIfPresent([Position].self, forKey: .positions) ?? []
        banks = (try? c.decode([Bank].self, forKey: .banks)) ?? []
        themes = (try? c.decode([Theme].self, forKey: .themes)) ?? []
        rules = (try? c.decode(RuleSet.self, forKey: .rules)) ?? RuleSet()
        exchanges = (try? c.decode([Exchange].self, forKey: .exchanges)) ?? []
        sources = (try? c.decode(SourcePreferences.self, forKey: .sources)) ?? SourcePreferences()
        notifications = (try? c.decode(NotificationSettings.self, forKey: .notifications)) ?? NotificationSettings()
        modifiedAt = (try? c.decode(Date.self, forKey: .modifiedAt)) ?? Date()
    }

    public var catalog: ExchangeCatalog { ExchangeCatalog(overrides: exchanges) }

    public func bank(_ id: UUID?) -> Bank? { banks.first { $0.id == id } }
    public func theme(_ id: UUID?) -> Theme? { themes.first { $0.id == id } }

    /// Stores a venue change as override (built-ins keep their id).
    public mutating func upsertExchange(_ e: Exchange) {
        if let i = exchanges.firstIndex(where: { $0.id == e.id }) { exchanges[i] = e } else { exchanges.append(e) }
    }

    /// Example depot used for the first start and for screenshots.
    public static func example() -> DepotFile {
        let comdirect = Bank(name: "Comdirect", sortIndex: 0)
        let sparkasse = Bank(name: "Sparkasse", sortIndex: 1)
        let uran = Theme(name: "Uran", sortIndex: 0, color: "#7FA34B")
        let oel = Theme(name: "Öl & Gas", sortIndex: 1, color: "#8A6A4A")
        let gold = Theme(name: "Gold", sortIndex: 2, color: "#C9A227")
        let tech = Theme(name: "Technologie", sortIndex: 3, color: "#4E7AA8")
        func d(_ s: String) -> DayKey { DayKey(iso: s)! }
        let positions: [Position] = [
            Position(name: "Cameco", isin: "CA13321L1085", listing: Listing(exchangeID: "TGAT", ticker: "CJ6"),
                     lots: [Lot(day: d("2021-03-15"), quantity: 120, totalCostEUR: 1_740)], bankID: comdirect.id, themeID: uran.id),
            Position(name: "Paladin Energy", isin: "AU000000PDN8", listing: Listing(exchangeID: "XASX", ticker: "PDN", symbols: ["yahoo": "PDN.AX", "ft": "PDN:ASX"]),
                     lots: [Lot(day: d("2023-06-01"), quantity: 400, totalCostEUR: 1_620)], bankID: sparkasse.id, themeID: uran.id),
            Position(name: "NexGen Energy", isin: "CA65340P1062", listing: Listing(exchangeID: "XTSE", ticker: "NXE", symbols: ["yahoo": "NXE.TO", "ft": "NXE:TOR"]),
                     lots: [Lot(day: d("2022-02-10"), quantity: 300, totalCostEUR: 1_350), Lot(day: d("2024-08-05"), quantity: 150, totalCostEUR: 840)],
                     bankID: comdirect.id, themeID: uran.id),
            Position(name: "Yellow Cake", isin: "JE00BF50RG45", listing: Listing(exchangeID: "XLON", ticker: "YCA", symbols: ["yahoo": "YCA.L", "ft": "YCA:LSE"]),
                     lots: [Lot(day: d("2024-01-22"), quantity: 250, totalCostEUR: 1_780)], bankID: sparkasse.id, themeID: uran.id),
            Position(name: "Skyharbour Resources", listing: Listing(exchangeID: "XTSX", ticker: "SYH", symbols: ["yahoo": "SYH.V", "ft": "SYH:CVE"]),
                     bankID: nil, themeID: uran.id),
            Position(name: "Equinor", isin: "NO0010096985", listing: Listing(exchangeID: "XOSL", ticker: "EQNR", symbols: ["yahoo": "EQNR.OL", "ft": "EQNR:OSL"]),
                     lots: [Lot(day: d("2020-11-02"), quantity: 80, totalCostEUR: 920)], bankID: comdirect.id, themeID: oel.id),
            Position(name: "TotalEnergies", isin: "FR0000120271", listing: Listing(exchangeID: "XPAR", ticker: "TTE", symbols: ["yahoo": "TTE.PA", "ft": "TTE:PAR"]),
                     lots: [Lot(day: d("2022-09-12"), quantity: 40, totalCostEUR: 2_050)], bankID: sparkasse.id, themeID: oel.id),
            Position(name: "Eni", isin: "IT0003132476", listing: Listing(exchangeID: "XMIL", ticker: "ENI", symbols: ["yahoo": "ENI.MI", "ft": "ENI:MIL"]),
                     lots: [Lot(day: d("2023-03-20"), quantity: 150, totalCostEUR: 1_950)], bankID: comdirect.id, themeID: oel.id),
            Position(name: "Newmont", isin: "US6516391066", listing: Listing(exchangeID: "XNYS", ticker: "NEM", symbols: ["yahoo": "NEM", "ft": "NEM:NYQ"]),
                     lots: [Lot(day: d("2024-04-03"), quantity: 100, totalCostEUR: 1_560)], bankID: comdirect.id, themeID: gold.id),
            Position(name: "Toyota Motor", isin: "JP3633400001", listing: Listing(exchangeID: "XTKS", ticker: "7203", symbols: ["yahoo": "7203.T", "ft": "7203:TYO"]),
                     lots: [Lot(day: d("2019-05-17"), quantity: 100, totalCostEUR: 1_150)], bankID: sparkasse.id, themeID: tech.id),
            Position(name: "SAP", isin: "DE0007164600", listing: Listing(exchangeID: "XETR", ticker: "SAP", symbols: ["yahoo": "SAP.DE", "ft": "SAP:GER"]),
                     lots: [Lot(day: d("2018-10-08"), quantity: 25, totalCostEUR: 2_380)], bankID: comdirect.id, themeID: tech.id),
            Position(name: "Nestlé", isin: "CH0038863350", listing: Listing(exchangeID: "XSWX", ticker: "NESN", symbols: ["yahoo": "NESN.SW", "ft": "NESN:SWX"]),
                     bankID: nil, themeID: nil),
            Position(name: "Bitcoin", assetType: .crypto, listing: Listing(exchangeID: "BFX", ticker: "BTCUSD", symbols: ["bitfinex": "tBTCUSD"]),
                     lots: [Lot(day: d("2020-12-01"), quantity: 0.15, totalCostEUR: 2_400)], bankID: nil, themeID: nil),
        ]
        return DepotFile(positions: positions, banks: [comdirect, sparkasse], themes: [uran, oel, gold, tech])
    }
}
