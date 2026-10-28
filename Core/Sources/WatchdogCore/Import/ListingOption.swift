import Foundation

/// One security at one venue, merged from the search results of several providers.
public struct ListingOption: Identifiable, Hashable, Sendable {
    public var id: String { "\(instrumentKey)|\(exchangeID ?? "?")|\(exchangeLabel)" }
    public var instrumentKey: String
    public var name: String
    public var isin: String?
    public var wkn: String?
    public var exchangeID: ExchangeID?
    public var exchangeLabel: String
    public var ticker: String
    public var currency: String?
    public var assetType: AssetType
    public var lastPrice: Double?
    public var candidates: [SearchCandidate]

    public init(instrumentKey: String, name: String, isin: String?, wkn: String?, exchangeID: ExchangeID?, exchangeLabel: String,
                ticker: String, currency: String?, assetType: AssetType, lastPrice: Double?, candidates: [SearchCandidate]) {
        self.instrumentKey = instrumentKey
        self.name = name
        self.isin = isin
        self.wkn = wkn
        self.exchangeID = exchangeID
        self.exchangeLabel = exchangeLabel
        self.ticker = ticker
        self.currency = currency
        self.assetType = assetType
        self.lastPrice = lastPrice
        self.candidates = candidates
    }

    public var providers: [ProviderID] {
        Array(Set(candidates.map(\.provider))).sorted {
            (ProviderID.defaultOrder.firstIndex(of: $0) ?? 99) < (ProviderID.defaultOrder.firstIndex(of: $1) ?? 99)
        }
    }

    public func listing() -> Listing {
        var symbols: [String: String] = [:]
        for c in candidates where symbols[c.provider.rawValue] == nil { symbols[c.provider.rawValue] = c.symbol }
        return Listing(exchangeID: exchangeID ?? "", ticker: ticker, currency: nil, symbols: symbols)
    }

    /// Groups search hits by instrument (ISIN, else name) and venue. Best matching instrument first,
    /// within an instrument the active venues in catalogue order.
    public static func build(_ cands: [SearchCandidate], query: String, catalog: ExchangeCatalog) -> [[ListingOption]] {
        // Learn ISINs from providers that know them, then attach them to name matches of the others.
        var isinByName: [String: String] = [:]
        for c in cands { if let i = c.isin { isinByName[Lenient.nameKey(c.name)] = isinByName[Lenient.nameKey(c.name)] ?? i } }
        let queryISIN = Lenient.isISIN(query) ? query.uppercased() : nil
        func key(_ c: SearchCandidate) -> String { c.isin ?? queryISIN ?? isinByName[Lenient.nameKey(c.name)] ?? Lenient.nameKey(c.name) }

        var groups: [String: [String: ListingOption]] = [:]
        var order: [String] = []
        for c in cands {
            let k = key(c)
            if groups[k] == nil { groups[k] = [:]; order.append(k) }
            let exKey = c.exchangeID ?? "\(c.provider.rawValue):\(c.exchangeLabel)"
            if var o = groups[k]![exKey] {
                // Ticker preference: Yahoo, FT, Twelve Data, then the rest (compared before adding this hit).
                let tickerOrder: [ProviderID] = [.yahoo, .ft, .twelvedata, .finnhub, .eodhd, .onvista, .lstc, .bitfinex]
                let rank: (ProviderID) -> Int = { tickerOrder.firstIndex(of: $0) ?? 9 }
                let best = o.candidates.map { rank($0.provider) }.min() ?? 9
                if rank(c.provider) < best || o.ticker.isEmpty { o.ticker = c.ticker }
                o.candidates.append(c)
                if o.isin == nil { o.isin = c.isin ?? (Lenient.isISIN(k) ? k : nil) }
                if o.wkn == nil { o.wkn = c.wkn }
                if o.lastPrice == nil { o.lastPrice = c.lastPrice }
                if o.currency == nil { o.currency = c.currency }
                if c.provider == .onvista { o.name = c.name }
                groups[k]![exKey] = o
            } else {
                groups[k]![exKey] = ListingOption(instrumentKey: k, name: c.name, isin: c.isin ?? (Lenient.isISIN(k) ? k : nil), wkn: c.wkn,
                                                  exchangeID: c.exchangeID, exchangeLabel: c.exchangeID.flatMap { catalog[$0]?.name } ?? c.exchangeLabel,
                                                  ticker: c.ticker, currency: c.currency, assetType: c.assetType, lastPrice: c.lastPrice, candidates: [c])
            }
        }
        let q = query.lowercased()
        let instruments = order.map { k -> [ListingOption] in
            let list = Array(groups[k]!.values)
            return list.sorted { a, b in
                let ia = a.exchangeID.flatMap { catalog[$0] }, ib = b.exchangeID.flatMap { catalog[$0] }
                let ra = ia == nil ? 2 : (ia!.isActive ? 0 : 1), rb = ib == nil ? 2 : (ib!.isActive ? 0 : 1)
                if ra != rb { return ra < rb }
                let oa = catalog.all.firstIndex { $0.id == a.exchangeID } ?? 999, ob = catalog.all.firstIndex { $0.id == b.exchangeID } ?? 999
                if oa != ob { return oa < ob }
                return a.exchangeLabel < b.exchangeLabel
            }
        }
        return instruments.sorted { a, b in
            func score(_ g: [ListingOption]) -> Int {
                guard let f = g.first else { return 0 }
                var s = g.flatMap(\.candidates).count
                if f.isin?.lowercased() == q { s += 1000 }
                if f.name.lowercased().hasPrefix(q) { s += 200 }
                if g.contains(where: { $0.ticker.lowercased() == q }) { s += 300 }
                if f.assetType == .stock { s += 20 }
                return s
            }
            return score(a) > score(b)
        }
    }
}

/// Picks the listing for an imported row.
public enum ImportResolver {
    public struct Choice: Sendable {
        public var option: ListingOption
        /// All venues of the same security, for the picker in the import list.
        public var alternatives: [ListingOption]
        /// Set when the security is taken at another venue than wanted.
        public var note: String?
    }

    /// Search queries in order of reliability.
    public static func queries(_ d: CSVImport.Draft) -> [String] {
        var q: [String] = []
        for s in [d.isin, d.wkn, d.ticker, d.name.isEmpty ? nil : d.name] {
            if let s, !s.isEmpty, !q.contains(s) { q.append(s) }
        }
        return q
    }

    /// The instrument group that really is the imported security, or nil if none is certain enough.
    public static func instrument(for d: CSVImport.Draft, in groups: [[ListingOption]], query: String) -> [ListingOption]? {
        if let isin = d.isin {
            if let g = groups.first(where: { $0.contains { $0.isin == isin } }) { return g }
            // ISIN search on a provider that does not echo the ISIN: the only result group is the match.
            if query == isin, groups.count == 1, groups[0].allSatisfy({ $0.isin == nil || $0.isin == isin }) { return groups[0] }
            return nil
        }
        if let wkn = d.wkn {
            if let g = groups.first(where: { $0.contains { $0.wkn == wkn } }) { return g }
            if query == wkn, groups.count == 1 { return groups[0] }
            return nil
        }
        if let t = d.ticker?.uppercased() {
            // The same company can arrive under slightly different names per venue ("Cameco Corp", "CAMECO CORP. REG. SHARES"):
            // groups with the ticker are merged when the first word of the name matches.
            let withTicker = groups.filter { $0.contains { $0.ticker.uppercased() == t } }
            if let first = withTicker.first {
                let word = { (s: String) in Lenient.nameKey(s).split(separator: " ").first.map(String.init) ?? "" }
                let key = word(d.name.isEmpty ? first[0].name : d.name)
                var seen = Set<String>()
                var merged: [ListingOption] = []
                for g in withTicker where g.contains(where: { word($0.name) == key && !key.isEmpty }) || g.map(\.id) == first.map(\.id) {
                    for o in g where !seen.contains(o.exchangeID ?? o.id) {
                        seen.insert(o.exchangeID ?? o.id)
                        merged.append(o)
                    }
                }
                return merged
            }
        }
        // Name only: accept the best group only if the names really match.
        let want = Lenient.nameKey(d.name)
        guard !want.isEmpty else { return nil }
        let wantFirst = want.split(separator: " ").first.map(String.init) ?? want
        return groups.first { g in
            g.contains { o in
                let have = Lenient.nameKey(o.name)
                return have == want || have.split(separator: " ").first.map(String.init) == wantFirst && wantFirst.count >= 3
            }
        }
    }

    /// The venue: the wanted one if the security trades there, otherwise the best other venue.
    public static func choose(_ d: CSVImport.Draft, group: [ListingOption], target: ExchangeID, catalog: ExchangeCatalog) -> Choice? {
        let usable = group.filter { $0.exchangeID != nil && catalog[$0.exchangeID!] != nil }
        guard !usable.isEmpty else { return nil }
        if let exact = usable.first(where: { $0.exchangeID == target }) {
            return Choice(option: exact, alternatives: usable, note: nil)
        }
        // Bought in a foreign currency (e.g. a US broker export): the home venue in that currency fits best.
        // Otherwise German venues in euro (where the customer buys), then the active venues, then the rest.
        let german = ["TGAT", "XETR", "XFRA", "GETX", "LSEX"]
        let buyCurrency = d.lots.first(where: { $0.cost != nil })?.currency
        let wantedTicker = d.ticker?.uppercased()
        func rank(_ o: ListingOption) -> Int {
            let e = catalog[o.exchangeID!]!
            var r: Int
            if let i = german.firstIndex(of: e.id), e.isActive { r = i } else if e.isActive { r = 10 + (catalog.all.firstIndex { $0.id == e.id } ?? 50) } else { r = 100 + (catalog.all.firstIndex { $0.id == e.id } ?? 50) }
            if let c = buyCurrency, c != "EUR" {
                if e.currency == c { r -= 1000 }
                if let t = wantedTicker, o.ticker.uppercased() == t { r -= 500 }
            }
            return r
        }
        let best = usable.min { rank($0) < rank($1) }!
        let wanted = catalog[target]?.name ?? target
        let got = catalog[best.exchangeID!]?.name ?? best.exchangeLabel
        let note = d.exchangeID != nil ? "nicht an \(wanted) gefunden, stattdessen \(got)" : "an \(wanted) nicht gehandelt, stattdessen \(got)"
        return Choice(option: best, alternatives: usable, note: note)
    }
}

public extension ImportResolver {
    enum Outcome: Sendable {
        case found(Choice)
        case notFound(String)
    }

    /// Searches with ISIN, WKN, ticker and name in this order and stops at the first certain match.
    /// A match whose company name does not fit the name in the file is never taken.
    static func resolve(_ d: CSVImport.Draft, target: ExchangeID, catalog: ExchangeCatalog,
                        search: (String) async -> [SearchCandidate]) async -> Outcome {
        var sawResults = false
        var otherCompany: String?
        for q in queries(d) {
            let cands = await search(q)
            if !cands.isEmpty { sawResults = true }
            let groups = ListingOption.build(cands, query: q, catalog: catalog)
            if let g = instrument(for: d, in: groups, query: q), let c = choose(d, group: g, target: d.exchangeID ?? target, catalog: catalog) {
                if let other = otherName(d, g) {
                    otherCompany = otherCompany ?? other
                    continue
                }
                return .found(c)
            }
        }
        if let other = otherCompany {
            return .notFound("Name passt nicht zum Treffer (\(other)), bitte von Hand hinzufügen")
        }
        return .notFound(sawResults ? "Kein eindeutiger Treffer, bitte von Hand hinzufügen" : "Bei keiner Datenquelle gefunden")
    }

    /// The name of the found security if it clearly is another company than the one named in the file, else nil.
    static func otherName(_ d: CSVImport.Draft, _ group: [ListingOption]) -> String? {
        let fileName = d.name.trimmingCharacters(in: .whitespaces)
        guard !fileName.isEmpty, fileName != d.identifier else { return nil }
        let names = Set(group.flatMap { [$0.name] + $0.candidates.map(\.name) })
        let verdicts = names.map { Lenient.sameCompany(fileName, $0) }
        guard verdicts.contains(false), !verdicts.contains(true) else { return nil }
        return group.first?.name
    }
}
