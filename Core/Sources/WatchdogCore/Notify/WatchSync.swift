import Foundation

/// What the iPhone hands to the Apple Watch: per value the reading of the traffic light and the current line value,
/// so the Watch can check the current price against the line on its own without loading years of history.
public struct WatchSnapshot: Codable, Sendable {
    public struct Row: Codable, Hashable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var isin: String?
        public var wkn: String?
        public var assetType: AssetType
        public var listing: Listing
        public var exchangeBadge: String
        /// Listing currency; the line is in this currency.
        public var currency: String
        /// Held (not only watched).
        public var held: Bool
        public var state: AmpelState
        /// The line was crossed within the last few sessions.
        public var fresh: Bool
        public var distance: Double?
        /// Current value of the traffic light line in the listing currency.
        public var line: Double?
        public var price: Double?
        public var priceEUR: Double?
        public var quoteTime: Date?
        /// Euro per unit of `currency`.
        public var eurPerUnit: Double?
        public var crossingDay: DayKey?
        public var crossingDown: Bool?
        /// Side of the line at the last confirmed price; a change is a crossing.
        public var above: Bool?
        /// No current data on the iPhone.
        public var stale: Bool

        public var position: Position {
            Position(id: id, name: name, isin: isin, wkn: wkn, assetType: assetType, listing: listing)
        }
    }

    public var rows: [Row]
    public var createdAt: Date
    public var depotValueEUR: Double?
    public var ampel: AmpelConfig
    /// Enabled crossing rules of the price with the traffic light line that send messages; the Watch checks only these.
    public var rules: [Rule]
    public var confirmOnClose: Bool
    public var exchanges: [Exchange]
    public var sources: SourcePreferences
    public var ledger: NotificationLedger

    public init(rows: [Row], createdAt: Date, depotValueEUR: Double?, ampel: AmpelConfig, rules: [Rule], confirmOnClose: Bool,
                exchanges: [Exchange], sources: SourcePreferences, ledger: NotificationLedger) {
        self.rows = rows
        self.createdAt = createdAt
        self.depotValueEUR = depotValueEUR
        self.ampel = ampel
        self.rules = rules
        self.confirmOnClose = confirmOnClose
        self.exchanges = exchanges
        self.sources = sources
        self.ledger = ledger
    }

    /// Below the line first (most urgent), then the freshly crossed, then by distance.
    public var sortedRows: [Row] {
        rows.sorted { a, b in
            func rank(_ r: Row) -> Int { r.state == .red ? 0 : r.fresh ? 1 : r.state == .yellow ? 2 : r.state == .unknown ? 4 : 3 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (a.distance ?? .infinity) < (b.distance ?? .infinity)
        }
    }

    public var belowCount: Int { rows.filter { $0.state == .red }.count }
    public var freshCount: Int { rows.filter(\.fresh).count }

    public var catalog: ExchangeCatalog { ExchangeCatalog(overrides: exchanges) }

    /// Built on the iPhone (or the Mac) from the evaluated depot.
    public static func make(depot: DepotFile, snapshot: EngineSnapshot, ledger: NotificationLedger, symbols: [String: String] = [:],
                            now: Date = Date()) -> WatchSnapshot {
        let catalog = depot.catalog
        var rows: [Row] = []
        var total = 0.0
        var anyValue = false
        for p in depot.positions {
            guard let ex = catalog[p.listing.exchangeID] else { continue }
            let m = snapshot.metrics[p.id]
            let line = m?.ampel.lineValue
            let price = m?.priceLocal
            if !p.isWatchOnly, let v = m?.valueEUR { total += v; anyValue = true }
            var listing = p.listing
            for (k, v) in symbols {
                let parts = k.split(separator: "|")
                guard parts.count == 2, String(parts[0]) == p.listing.key, listing.symbols[String(parts[1])] == nil else { continue }
                listing.symbols[String(parts[1])] = v
            }
            rows.append(Row(id: p.id, name: p.name, isin: p.isin, wkn: p.wkn, assetType: p.assetType, listing: listing,
                            exchangeBadge: ex.badge, currency: m?.currency ?? p.listing.currency ?? ex.currency, held: !p.isWatchOnly,
                            state: m?.ampel.state ?? .unknown, fresh: m?.ampel.isFresh ?? false, distance: m?.ampel.distancePercent,
                            line: line, price: price, priceEUR: m?.priceEUR, quoteTime: m?.quoteTime, eurPerUnit: m?.fxRateNow,
                            crossingDay: m?.ampel.lastCrossing?.day, crossingDown: m?.ampel.lastCrossing.map { $0.direction == .down },
                            above: price.flatMap { pr in line.map { pr >= $0 } },
                            stale: snapshot.freshness[p.listing.key]?.isProblem ?? false))
        }
        let used = Set(depot.positions.map(\.listing.exchangeID))
        let rules = depot.rules.rules.filter { r in
            r.enabled && r.notify && r.condition.a == .price && r.condition.b == depot.rules.ampel.line
                && (r.condition.kind == .crossesBelow || r.condition.kind == .crossesAbove)
        }
        return WatchSnapshot(rows: rows, createdAt: now, depotValueEUR: anyValue ? total : nil, ampel: depot.rules.ampel, rules: rules,
                             confirmOnClose: depot.rules.confirmOnClose, exchanges: catalog.all.filter { used.contains($0.id) },
                             sources: depot.sources, ledger: ledger)
    }

    /// Compact transfer format for WatchConnectivity (the context is limited to a few dozen kilobytes).
    public func encoded() throws -> Data {
        let json = try DepotStore.encoder().encode(self)
        #if canImport(Darwin)
        if let packed = try? (json as NSData).compressed(using: .lzfse) as Data { return packed }
        #endif
        return json
    }

    public static func decode(_ data: Data) throws -> WatchSnapshot {
        var json = data
        #if canImport(Darwin)
        if data.first != UInt8(ascii: "{"), let unpacked = try? (data as NSData).decompressed(using: .lzfse) as Data { json = unpacked }
        #endif
        return try DepotStore.decoder().decode(WatchSnapshot.self, from: json)
    }
}

/// The Watch's own check: a fresh price against the line the iPhone sent.
public enum WatchCheck {
    /// Applies a new price to a row and returns the crossing events it causes.
    /// Event ids are the same as on Mac and iPhone ("position|rule|day"), so the ledger recognises them everywhere.
    public static func apply(_ q: Quote, to row: inout WatchSnapshot.Row, snapshot: WatchSnapshot, exchange: Exchange,
                             now: Date = Date()) -> [SignalEvent] {
        guard q.price > 0, q.currency == row.currency, let line = row.line, line > 0 else { return [] }
        let previous = row.price
        row.price = q.price
        row.quoteTime = q.time
        row.priceEUR = row.eurPerUnit.map { q.price * $0 }
        row.distance = (q.price / line - 1) * 100
        row.state = Self.state(q.price, line: line, ampel: snapshot.ampel)
        row.stale = false

        // A large jump may be a wrong tick; without a second source on the Watch it waits for Mac or iPhone.
        if let p = previous, p > 0, abs(q.price / p - 1) > MarketEngine.jumpThreshold(exchange) { return [] }
        // Signals on closing prices only: while the venue trades, the side is not confirmed yet.
        if snapshot.confirmOnClose && exchange.isOpen(at: now) { return [] }

        let nowAbove = q.price >= line
        defer { row.above = nowAbove }
        guard let wasAbove = row.above, wasAbove != nowAbove else { return [] }
        let day = DayKey(date: q.time, timeZone: exchange.tz)
        row.crossingDay = day
        row.crossingDown = !nowAbove
        row.fresh = true
        let kind: Condition.Kind = nowAbove ? .crossesAbove : .crossesBelow
        return snapshot.rules.filter { $0.condition.kind == kind }.map { rule in
            SignalState.event(id: "\(row.id.uuidString)|\(rule.id)|\(day.value)", rule: rule, day: day, position: row.position,
                              exchange: exchange, priceEUR: row.priceEUR, lineEUR: row.eurPerUnit.map { line * $0 },
                              distance: row.distance, now: now)
        }
    }

    static func state(_ price: Double, line: Double, ampel: AmpelConfig) -> AmpelState {
        let dist = (price / line - 1) * 100
        var s: AmpelState = dist >= 0 ? .green : .red
        if ampel.yellowBandPercent > 0 && abs(dist) < ampel.yellowBandPercent && (ampel.yellowMode == .bothSides || dist >= 0) {
            s = .yellow
        }
        return s
    }
}

public extension NotificationLedger {
    /// A check counts as working when most values got current data.
    static func healthy(_ freshness: [String: Freshness]) -> Bool {
        guard !freshness.isEmpty else { return true }
        let bad = freshness.values.filter(\.isProblem).count
        return Double(bad) < Double(freshness.count) * 0.5
    }
}
