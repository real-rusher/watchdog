import Foundation

/// Deterministic made-up prices for layout tests (extreme values, long names, fresh crossings).
/// Never used for a real depot: only the screenshot run with `--stress` registers it.
public final class DemoProvider: MarketDataProvider, @unchecked Sendable {
    public enum Shape: Sendable {
        case trend
        /// Falls through the 200-day line `daysAgo` sessions before today.
        case crossDown(Int)
        case crossUp(Int)
        /// Ends almost exactly on the 200-day line.
        case onLine
        /// Today's price is far away from yesterday's close (to test the plausibility check).
        case crash
    }

    public struct Spec: Sendable {
        public var start: Double
        public var end: Double
        public var currency: String
        public var shape: Shape
        public init(_ start: Double, _ end: Double, _ currency: String, _ shape: Shape = .trend) {
            self.start = start
            self.end = end
            self.currency = currency
            self.shape = shape
        }
    }

    public let id: ProviderID = .yahoo
    public let capabilities: ProviderCapabilities = [.quote, .history]
    public let gate = RequestGate(maxConcurrent: 8, minInterval: 0)
    let specs: [String: Spec]

    public init(specs: [String: Spec]) { self.specs = specs }

    public func supports(_ exchange: Exchange) -> Bool { true }

    public func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        let s = ref.listing.symbols["yahoo"] ?? ref.listing.ticker
        guard specs[s] != nil else { throw ProviderError.notFound(s) }
        return s
    }

    func series(_ symbol: String) -> [Bar] {
        guard let spec = specs[symbol] else { return [] }
        let today = DayKey.today(in: .berlin)
        var days: [DayKey] = []
        var d = today.adding(days: -1)
        while days.count < 420 {
            if d.weekday != 1 && d.weekday != 7 { days.append(d) }
            d = d.adding(days: -1)
        }
        days.reverse()
        let n = days.count
        let seed = Double(symbol.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 })
        var closes: [Double] = (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            let base = spec.start * pow(spec.end / spec.start, t)
            return base * (1 + 0.035 * sin(Double(i) / 9 + seed) + 0.015 * sin(Double(i) / 2.3 + seed / 3))
        }
        switch spec.shape {
        case .crossDown(let k):
            // Long rise, then a sharp drop under the line k sessions ago.
            let cut = n - 1 - k
            for i in cut..<n { closes[i] = closes[cut - 1] * 0.62 }
        case .crossUp(let k):
            for i in 0..<n { closes[i] = spec.start * pow(spec.end / spec.start, Double(i) / Double(n)) }
            let cut = n - 1 - k
            for i in cut..<n { closes[i] = closes[cut - 1] * 1.55 }
        case .onLine:
            let avg = closes.suffix(200).reduce(0, +) / 200
            closes[n - 1] = avg * 1.004
        default:
            break
        }
        return zip(days, closes).map { Bar(day: $0, close: $1) }
    }

    public func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        guard let spec = specs[symbol] else { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: series(symbol).filter { $0.day >= from }, currency: spec.currency, source: id)
    }

    public func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        guard let spec = specs[symbol], let last = series(symbol).last else { throw ProviderError.notFound(symbol) }
        let factor: Double
        switch spec.shape {
        case .crash: factor = 0.52
        case .onLine, .crossDown, .crossUp: factor = 1
        default: factor = 1.012
        }
        return Quote(price: last.close * factor, time: Date().addingTimeInterval(-300), previousClose: last.close, currency: spec.currency, source: id)
    }
}

public enum DemoData {
    /// A depot that pushes every column to its limits.
    public static func stress() -> (DepotFile, DemoProvider) {
        let comdirect = Bank(name: "Comdirect", sortIndex: 0)
        let spk = Bank(name: "Sparkasse Aachen", sortIndex: 1)
        let longBank = Bank(name: "Consorsbank Wertpapierdepot mit einem besonders langen Namen", sortIndex: 2)
        let themes = [
            Theme(name: "Uran", sortIndex: 0, color: "#7FA34B"),
            Theme(name: "Edelmetalle und Rohstoffe aus aller Welt", sortIndex: 1, color: "#C9A227"),
            Theme(name: "Technologie", sortIndex: 2, color: "#4E7AA8"),
        ]
        func d(_ s: String) -> DayKey { DayKey(iso: s)! }
        var specs: [String: DemoProvider.Spec] = [:]
        var positions: [Position] = []
        func add(_ name: String, _ ex: ExchangeID, _ sym: String, _ spec: DemoProvider.Spec, qty: Double? = nil, cost: Double? = nil,
                 bank: Bank? = nil, theme: Int? = nil, isin: String? = nil, lots: [Lot]? = nil) {
            specs[sym] = spec
            let l = lots ?? qty.map { [Lot(day: d("2021-06-01"), quantity: $0, totalCostEUR: cost ?? 0)] } ?? []
            positions.append(Position(name: name, isin: isin, listing: Listing(exchangeID: ex, ticker: sym.uppercased(), symbols: ["yahoo": sym]),
                                      lots: l, bankID: bank?.id, themeID: theme.map { themes[$0].id }))
        }
        add("Compagnie Financière Richemont SA Namensaktien A", "XSWX", "cfr", .init(120, 146, "CHF"), qty: 1_250, cost: 150_000, bank: comdirect, theme: 2, isin: "CH0210483332")
        add("Berkshire Hathaway Inc. Class A", "XNYS", "brk", .init(600_000, 731_000, "USD"), qty: 3, cost: 1_420_000, bank: comdirect, theme: 2)
        add("Mini Penny Mining Corp.", "XTSX", "penny", .init(0.0021, 0.00093, "CAD"), qty: 2_500_000, cost: 9_000, bank: spk, theme: 0)
        add("Rakete Biotech", "XNAS", "rocket", .init(1.2, 86, "USD"), qty: 10_000, cost: 12_000, bank: spk, theme: 2)
        add("Riesenposition Versorger AG", "XETR", "huge", .init(98, 123.45, "EUR"), qty: 100_000, cost: 9_870_000, bank: comdirect)
        add("Ohne Kaufpreis AG", "XETR", "nocost", .init(40, 52, "EUR"), qty: 300, cost: 0, bank: comdirect)
        add("Toyota Motor Corp.", "XTKS", "toyota", .init(2_100, 2_850, "JPY"), qty: 400, cost: 5_200, bank: spk, theme: 2)
        add("Yellow Cake plc", "XLON", "ycake", .init(4.1, 5.12, "GBP"), qty: 2_000, cost: 9_400, bank: longBank, theme: 0)
        add("Frisch gefallen Uranium Ltd.", "XETR", "crossdown", .init(10, 18, "EUR", .crossDown(1)), qty: 500, cost: 6_000, bank: comdirect, theme: 0)
        add("Frisch gestiegen Gold Corp.", "TGAT", "crossup", .init(30, 22, "EUR", .crossUp(2)), qty: 200, cost: 7_000, bank: spk, theme: 1)
        add("Knapp an der Linie SE", "XETR", "online", .init(60, 64, "EUR", .onLine), qty: 50, cost: 3_000, bank: longBank, theme: 1)
        add("Absturz AG (Kurs unbestätigt)", "XETR", "crash", .init(20, 24, "EUR", .crash), qty: 1_000, cost: 21_000, bank: longBank, theme: 2)
        add("Keine Daten GmbH", "XFRA", "unknown-symbol-xyz", .init(1, 1, "EUR"), qty: 10, cost: 100, bank: spk)
        specs["unknown-symbol-xyz"] = nil
        add("Beobachtung mit einem extrem langen Namen, der auf keinem Bildschirm in eine Zeile passt", "XNYS", "watch", .init(15, 31, "USD"), theme: 1)
        add("Bitcoin", "BFX", "btc", .init(28_000, 98_500, "USD"), qty: 0.37, cost: 9_800, bank: longBank)
        add("Mehrfachkauf Minen Inc.", "XTSE", "multi", .init(12, 19, "CAD"), bank: comdirect, theme: 1,
            lots: [Lot(day: d("2020-02-03"), quantity: 100, totalCostEUR: 800), Lot(day: d("2022-05-10"), quantity: 250, totalCostEUR: 2_600),
                   Lot(day: d("2024-09-01"), quantity: 1_000, totalCostEUR: 12_500)])
        for i in 1...24 {
            let up = i % 3 != 0
            add(String(format: "Rohstoffwert %02d", i), i % 2 == 0 ? "XASX" : "XOSL", "fill\(i)",
                .init(10 + Double(i), up ? 14 + Double(i) * 1.3 : 6 + Double(i) * 0.4, i % 2 == 0 ? "AUD" : "NOK"),
                qty: Double(100 * i), cost: Double(900 * i), bank: i % 2 == 0 ? spk : comdirect, theme: i % 3)
        }
        let depot = DepotFile(positions: positions, banks: [comdirect, spk, longBank], themes: themes)
        return (depot, DemoProvider(specs: specs))
    }
}
