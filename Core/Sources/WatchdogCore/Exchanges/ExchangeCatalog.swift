import Foundation

/// Built-in list of venues plus user customizations.
public struct ExchangeCatalog: Sendable {
    public private(set) var all: [Exchange]
    private var byID: [ExchangeID: Int]

    public init(overrides: [Exchange] = []) {
        var list = ExchangeCatalog.defaults
        for o in overrides {
            if let i = list.firstIndex(where: { $0.id == o.id }) { list[i] = o } else { list.append(o) }
        }
        self.all = list
        self.byID = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
    }

    public subscript(id: ExchangeID) -> Exchange? {
        guard let i = byID[id] else { return nil }
        return all[i]
    }

    public var active: [Exchange] { all.filter(\.isActive) }

    /// Maps a provider specific exchange code to a venue. Active venues win over inactive ones.
    public func match(_ provider: ProviderID, code: String) -> Exchange? {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return nil }
        let hits = all.filter { $0.matchCodes(provider).contains { $0.caseInsensitiveCompare(c) == .orderedSame } }
        return hits.first(where: \.isActive) ?? hits.first
    }

    /// Yahoo symbols carry the venue as suffix ("7203.T"); US symbols have none and need the exchange code.
    public func matchYahoo(symbol: String, exchangeCode: String?) -> Exchange? {
        if let dot = symbol.lastIndex(of: "."), dot != symbol.startIndex {
            let suffix = String(symbol[dot...])
            let hits = all.filter { $0.code(.yahoo)?.caseInsensitiveCompare(suffix) == .orderedSame }
            if let e = hits.first(where: \.isActive) ?? hits.first { return e }
        }
        if let ex = exchangeCode, let e = match(.yahoo, code: ex) { return e }
        return nil
    }

    /// Finds a venue by free text (CSV import, user input).
    public func matchName(_ text: String) -> Exchange? {
        let t = text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !t.isEmpty else { return nil }
        func norm(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let ordered = all.filter(\.isActive) + all.filter { !$0.isActive }
        if let e = ordered.first(where: { norm($0.name) == t || norm($0.id) == t || norm($0.badge) == t || $0.aliases.contains(where: { norm($0) == t }) }) {
            return e
        }
        return ordered.first(where: { norm($0.name).contains(t) || $0.aliases.contains(where: { norm($0).contains(t) || t.contains(norm($0)) }) })
    }

    // MARK: - Defaults

    private static func hm(_ h: Int, _ m: Int = 0) -> Int { h * 60 + m }

    public static let defaults: [Exchange] = [
        Exchange(id: "TGAT", name: "Tradegate", badge: "TGT", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["onvista": "_GAT", "tradegate": "TG"],
                 aliases: ["Tradegate", "Tradegate Exchange", "TGT", "Tradegate BSX", "TGX"]),
        Exchange(id: "XETR", name: "Xetra", badge: "XETRA", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".DE", "yahoo.match": "GER", "onvista": "_GER", "ft": "GER", "eodhd": "XETRA",
                         "twelvedata": "XETR", "alphavantage": "DEX", "finnhub": ".DE"],
                 aliases: ["Xetra", "XETRA", "ETR", "GER", "Deutsche Börse"]),
        Exchange(id: "XLON", name: "London", badge: "LSE", country: "GB", currency: "GBP", timeZone: "Europe/London",
                 opens: hm(8), closes: hm(16, 30),
                 codes: ["yahoo": ".L", "yahoo.match": "LSE,IOB", "onvista": "_LSE", "ft": "LSE", "eodhd": "LSE",
                         "twelvedata": "XLON", "alphavantage": "LON", "finnhub": ".L"],
                 aliases: ["London", "LSE", "London Stock Exchange", "LON", "AIM"]),
        Exchange(id: "XTKS", name: "Tokio", badge: "TYO", country: "JP", currency: "JPY", timeZone: "Asia/Tokyo",
                 opens: hm(9), closes: hm(15, 30),
                 codes: ["yahoo": ".T", "yahoo.match": "JPX,TYO", "ft": "TYO", "eodhd": "TSE", "twelvedata": "XJPX",
                         "twelvedata.match": "XTKS", "finnhub": ".T"],
                 aliases: ["Tokio", "Tokyo", "TSE", "TYO", "JPX", "Tokyo Stock Exchange"]),
        Exchange(id: "SSME", name: "First North Stockholm", badge: "FN STO", country: "SE", currency: "SEK", timeZone: "Europe/Stockholm",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".ST", "yahoo.match": "STO", "ft": "STO", "eodhd": "ST", "twelvedata": "SSME",
                         "twelvedata.match": "XSTO,FNSE", "finnhub": ".ST"],
                 aliases: ["First North", "First North Stockholm", "Nasdaq First North", "Stockholm", "STO"]),
        Exchange(id: "BFX", name: "Bitfinex", badge: "BFX", country: "", currency: "USD", timeZone: "UTC",
                 opens: 0, closes: 24 * 60, kind: .crypto,
                 codes: ["bitfinex": "BFX"],
                 aliases: ["Bitfinex", "BFX"]),
        Exchange(id: "XFRA", name: "Frankfurt", badge: "FRA", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".F", "yahoo.match": "FRA", "onvista": "_FRA", "ft": "FRA", "eodhd": "F",
                         "twelvedata": "XFRA", "alphavantage": "FRK", "finnhub": ".F"],
                 aliases: ["Frankfurt", "FSE", "FRA", "Börse Frankfurt", "Frankfurter Wertpapierbörse"]),
        Exchange(id: "GETX", name: "gettex", badge: "GTX", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["onvista": "_TRO"],
                 aliases: ["gettex", "Gettex", "München gettex", "GTX"]),
        Exchange(id: "XTSX", name: "TSX Venture", badge: "TSXV", country: "CA", currency: "CAD", timeZone: "America/Toronto",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": ".V", "yahoo.match": "VAN,CVE", "ft": "CVE", "eodhd": "V", "twelvedata": "XTSX",
                         "alphavantage": "TRV", "finnhub": ".V"],
                 aliases: ["TSX Venture", "TSXV", "TSX-V", "Venture", "CVE", "TSX Venture Exchange"]),
        Exchange(id: "XTSE", name: "Toronto", badge: "TSX", country: "CA", currency: "CAD", timeZone: "America/Toronto",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": ".TO", "yahoo.match": "TOR", "ft": "TOR", "eodhd": "TO", "twelvedata": "XTSE",
                         "alphavantage": "TRT", "finnhub": ".TO"],
                 aliases: ["Toronto", "TSX", "Toronto Stock Exchange", "TOR"]),
        Exchange(id: "XNAS", name: "Nasdaq", badge: "NSDQ", country: "US", currency: "USD", timeZone: "America/New_York",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": "", "yahoo.match": "NMS,NGM,NCM,NAS,NIM", "onvista": "_NMS", "onvista.match": "_NAS,_NCM,_NGM",
                         "ft": "NSQ", "ft.match": "NAQ,NMQ", "eodhd": "US", "twelvedata": "XNAS", "twelvedata.match": "XNGS,XNMS,XNCM",
                         "alphavantage": "", "finnhub": ""],
                 aliases: ["Nasdaq", "NASDAQ", "NSQ", "Nasdaq GS"]),
        Exchange(id: "XNYS", name: "NYSE", badge: "NYSE", country: "US", currency: "USD", timeZone: "America/New_York",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": "", "yahoo.match": "NYQ,NYS", "onvista": "_NYS", "ft": "NYQ", "ft.match": "NYS",
                         "eodhd": "US", "twelvedata": "XNYS", "alphavantage": "", "finnhub": ""],
                 aliases: ["NYSE", "New York", "New York Stock Exchange", "NYQ"]),
        Exchange(id: "OOTC", name: "FINRA Other OTC", badge: "OTC", country: "US", currency: "USD", timeZone: "America/New_York",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": "", "yahoo.match": "PNK,OQB,OQX,OBB,OEM,OGM", "onvista": "_PNK", "ft": "PKC", "ft.match": "PKL,QXE,PNK",
                         "eodhd": "US", "twelvedata": "PINX", "twelvedata.match": "OTCM,OTCQ,OOTC", "alphavantage": "", "finnhub": ""],
                 aliases: ["OTC", "FINRA Other OTC Issues", "FINRA", "Pink Sheets", "OTC Markets", "Nasdaq OTC", "OTCQX", "OTCQB"]),
        Exchange(id: "XPAR", name: "Euronext Paris", badge: "PAR", country: "FR", currency: "EUR", timeZone: "Europe/Paris",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".PA", "yahoo.match": "PAR", "ft": "PAR", "eodhd": "PA", "twelvedata": "XPAR",
                         "alphavantage": "PAR", "finnhub": ".PA"],
                 aliases: ["Paris", "Euronext Paris", "EPA"]),
        Exchange(id: "XMIL", name: "Euronext Mailand", badge: "MIL", country: "IT", currency: "EUR", timeZone: "Europe/Rome",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".MI", "yahoo.match": "MIL", "ft": "MIL", "eodhd": "MI", "twelvedata": "XMIL", "finnhub": ".MI"],
                 aliases: ["Mailand", "Milan", "Milano", "Borsa Italiana", "Euronext Milan"]),
        Exchange(id: "LSEX", name: "LS Exchange", badge: "LSX", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(7, 30), closes: hm(23),
                 codes: ["onvista": "_LSX", "lstc": "1"],
                 aliases: ["LS Exchange", "LSX", "Lang & Schwarz Exchange", "LS-X"]),
        Exchange(id: "XSWX", name: "SIX Swiss Exchange", badge: "SIX", country: "CH", currency: "CHF", timeZone: "Europe/Zurich",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".SW", "yahoo.match": "EBS,VTX", "onvista": "_SWX", "ft": "SWX", "ft.match": "VTX",
                         "eodhd": "SW", "twelvedata": "XSWX", "finnhub": ".SW"],
                 aliases: ["SIX", "Zürich", "Zurich", "SIX Swiss", "Swiss Exchange", "SWX"]),
        Exchange(id: "XOSL", name: "Euronext Oslo", badge: "OSL", country: "NO", currency: "NOK", timeZone: "Europe/Oslo",
                 opens: hm(9), closes: hm(16, 20),
                 codes: ["yahoo": ".OL", "yahoo.match": "OSL", "ft": "OSL", "eodhd": "OL", "twelvedata": "XOSL", "finnhub": ".OL"],
                 aliases: ["Oslo", "Euronext Oslo", "Oslo Børs", "Oslo Bors"]),
        Exchange(id: "XASX", name: "ASX Sydney", badge: "ASX", country: "AU", currency: "AUD", timeZone: "Australia/Sydney",
                 opens: hm(10), closes: hm(16),
                 codes: ["yahoo": ".AX", "yahoo.match": "ASX", "ft": "ASX", "eodhd": "AU", "twelvedata": "XASX", "finnhub": ".AX"],
                 aliases: ["ASX", "Sydney", "Australian Securities Exchange", "Australien"]),

        // Further venues, hidden in the picker until activated in the settings.
        Exchange(id: "XSTU", name: "Stuttgart", badge: "STU", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".SG", "yahoo.match": "STU", "onvista": "_STU", "ft": "STU", "eodhd": "STU", "twelvedata": "XSTU"],
                 aliases: ["Stuttgart", "Börse Stuttgart", "STU"], isActive: false),
        Exchange(id: "XMUN", name: "München", badge: "MUN", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".MU", "yahoo.match": "MUN", "onvista": "_MUN", "ft": "MUN", "eodhd": "MU", "twelvedata": "XMUN"],
                 aliases: ["München", "Muenchen", "Munich", "MUN"], isActive: false),
        Exchange(id: "XDUS", name: "Düsseldorf", badge: "DUS", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".DU", "yahoo.match": "DUS", "onvista": "_DUS", "ft": "DUS", "eodhd": "DU", "twelvedata": "XDUS"],
                 aliases: ["Düsseldorf", "Duesseldorf", "DUS"], isActive: false),
        Exchange(id: "XHAM", name: "Hamburg", badge: "HAM", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".HM", "yahoo.match": "HAM", "onvista": "_HAM", "ft": "HAM", "eodhd": "HM", "twelvedata": "XHAM"],
                 aliases: ["Hamburg", "HAM"], isActive: false),
        Exchange(id: "XHAN", name: "Hannover", badge: "HAN", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".HA", "yahoo.match": "HAN", "onvista": "_HAN", "ft": "HAN", "eodhd": "HA", "twelvedata": "XHAN"],
                 aliases: ["Hannover", "HAN"], isActive: false),
        Exchange(id: "XBER", name: "Berlin", badge: "BER", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["yahoo": ".BE", "yahoo.match": "BER", "ft": "BER", "eodhd": "BE", "twelvedata": "XBER"],
                 aliases: ["Berlin", "BER"], isActive: false),
        Exchange(id: "QUOT", name: "Quotrix", badge: "QTX", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(23),
                 codes: ["onvista": "_QUO"], aliases: ["Quotrix"], isActive: false),
        Exchange(id: "BAAD", name: "Baader Trading", badge: "BAA", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(8), closes: hm(22),
                 codes: ["onvista": "@_BBF"], aliases: ["Baader", "Baader Trading"], isActive: false),
        Exchange(id: "LSTC", name: "L&S Tradecenter", badge: "L&S", country: "DE", currency: "EUR", timeZone: "Europe/Berlin",
                 opens: hm(7, 30), closes: hm(23),
                 codes: ["onvista": "@_LUSG"], aliases: ["Lang & Schwarz", "L&S", "Lang und Schwarz", "L&S Tradecenter"], isActive: false),
        Exchange(id: "XSTO", name: "Nasdaq Stockholm", badge: "STO", country: "SE", currency: "SEK", timeZone: "Europe/Stockholm",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".ST", "yahoo.match": "STO", "ft": "STO", "eodhd": "ST", "twelvedata": "XSTO", "finnhub": ".ST"],
                 aliases: ["Nasdaq Stockholm", "Stockholmsbörsen"], isActive: false),
        Exchange(id: "XASE", name: "NYSE American", badge: "AMEX", country: "US", currency: "USD", timeZone: "America/New_York",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": "", "yahoo.match": "ASE", "ft": "ASQ", "eodhd": "US", "twelvedata": "XASE", "alphavantage": "", "finnhub": ""],
                 aliases: ["NYSE American", "AMEX", "NYSE MKT"], isActive: false),
        Exchange(id: "XAMS", name: "Euronext Amsterdam", badge: "AMS", country: "NL", currency: "EUR", timeZone: "Europe/Amsterdam",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".AS", "yahoo.match": "AMS", "ft": "AEX", "eodhd": "AS", "twelvedata": "XAMS", "finnhub": ".AS"],
                 aliases: ["Amsterdam", "Euronext Amsterdam", "AEX"], isActive: false),
        Exchange(id: "XBRU", name: "Euronext Brüssel", badge: "BRU", country: "BE", currency: "EUR", timeZone: "Europe/Brussels",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".BR", "yahoo.match": "BRU", "ft": "BRU", "eodhd": "BR", "twelvedata": "XBRU", "finnhub": ".BR"],
                 aliases: ["Brüssel", "Brussels", "Euronext Brussels"], isActive: false),
        Exchange(id: "XWBO", name: "Wien", badge: "VIE", country: "AT", currency: "EUR", timeZone: "Europe/Vienna",
                 opens: hm(9), closes: hm(17, 30),
                 codes: ["yahoo": ".VI", "yahoo.match": "VIE", "ft": "VIE", "eodhd": "VI", "twelvedata": "XWBO", "finnhub": ".VI"],
                 aliases: ["Wien", "Vienna", "Wiener Börse"], isActive: false),
        Exchange(id: "XCSE", name: "Kopenhagen", badge: "CPH", country: "DK", currency: "DKK", timeZone: "Europe/Copenhagen",
                 opens: hm(9), closes: hm(17),
                 codes: ["yahoo": ".CO", "yahoo.match": "CPH", "ft": "CPH", "eodhd": "CO", "twelvedata": "XCSE", "finnhub": ".CO"],
                 aliases: ["Kopenhagen", "Copenhagen"], isActive: false),
        Exchange(id: "XHEL", name: "Helsinki", badge: "HEL", country: "FI", currency: "EUR", timeZone: "Europe/Helsinki",
                 opens: hm(10), closes: hm(18, 30),
                 codes: ["yahoo": ".HE", "yahoo.match": "HEL", "ft": "HEL", "eodhd": "HE", "twelvedata": "XHEL", "finnhub": ".HE"],
                 aliases: ["Helsinki"], isActive: false),
        Exchange(id: "XHKG", name: "Hongkong", badge: "HKG", country: "HK", currency: "HKD", timeZone: "Asia/Hong_Kong",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": ".HK", "yahoo.match": "HKG", "ft": "HKG", "eodhd": "HK", "twelvedata": "XHKG", "finnhub": ".HK"],
                 aliases: ["Hongkong", "Hong Kong", "HKEX"], isActive: false),
        Exchange(id: "XJSE", name: "Johannesburg", badge: "JSE", country: "ZA", currency: "ZAR", timeZone: "Africa/Johannesburg",
                 opens: hm(9), closes: hm(17),
                 codes: ["yahoo": ".JO", "yahoo.match": "JNB", "ft": "JNB", "eodhd": "JSE", "twelvedata": "XJSE", "finnhub": ".JO"],
                 aliases: ["Johannesburg", "JSE"], isActive: false),
        Exchange(id: "XCNQ", name: "CSE Kanada", badge: "CSE", country: "CA", currency: "CAD", timeZone: "America/Toronto",
                 opens: hm(9, 30), closes: hm(16),
                 codes: ["yahoo": ".CN", "yahoo.match": "CNQ", "onvista": "_PUR", "ft": "CNQ", "twelvedata": "XCNQ"],
                 aliases: ["CSE", "Canadian Securities Exchange", "CNSX"], isActive: false),
    ]
}
