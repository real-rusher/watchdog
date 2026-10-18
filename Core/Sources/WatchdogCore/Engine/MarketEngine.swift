import Foundation

public struct ListingStatus: Sendable {
    public var historySource: ProviderID?
    public var quoteSource: ProviderID?
    public var lastError: String?
    public var attempts: [DataRouter.Attempt] = []
    public var updatedAt: Date?
    public var isLoading = false

    public init() {}
}

public struct RefreshSummary: Sendable {
    public var quotesUpdated = 0
    public var historiesUpdated = 0
    public var failures = 0
    public var events: [SignalEvent] = []
    public var startedAt = Date()
    public var finishedAt: Date?

    public init() {}
}

public struct EngineSnapshot: Sendable {
    public var metrics: [UUID: PositionMetrics]
    public var status: [String: ListingStatus]
    public var fx: FXTable
    public var health: [ProviderID: ProviderHealth.Status]
    public var lastRefresh: Date?
    public var eventLog: [SignalEvent]
}

/// Fetches, caches and evaluates market data for a depot.
public actor MarketEngine {
    public let router: DataRouter
    public let http: HTTPClient
    private let cache: CacheStore?
    private let fx: FXService
    private let symbols: SymbolCache

    private var histories: [String: PriceHistory] = [:]
    private var quotes: [String: Quote] = [:]
    private var status: [String: ListingStatus] = [:]
    private var lastQuoteAttempt: [String: Date] = [:]
    private var lastHistoryAttempt: [String: Date] = [:]
    private var signalState = SignalState()
    private var lastRefresh: Date?
    private var dirtyHistories: Set<String> = []

    /// Seconds between quote updates while a venue is open.
    public var quoteInterval: TimeInterval = 15 * 60
    /// Years of history kept for charts (plus the run-up needed for the longest line).
    public var historyYears = 5

    public init(cacheDir: URL?, router: DataRouter = DataRouter(), http: HTTPClient = HTTPClient()) {
        self.router = router
        self.http = http
        self.cache = cacheDir.map { CacheStore(dir: $0) }
        self.fx = FXService(http: http)
        self.symbols = SymbolCache()
    }

    public func setQuoteInterval(_ s: TimeInterval) { quoteInterval = max(60, s) }

    // MARK: Cache

    public func loadCache() async {
        guard let cache else { return }
        histories = await cache.loadHistories()
        quotes = await cache.read([String: Quote].self, "quotes.json") ?? [:]
        if let s = await cache.read([String: String].self, "symbols.json") {
            for (k, v) in s {
                let parts = k.split(separator: "|")
                if parts.count == 2, let p = ProviderID(rawValue: String(parts[1])) { await symbols.put(String(parts[0]), p, v) }
            }
            _ = await symbols.takeDirty()
        }
        if let table = await cache.read(FXTable.self, "fx.json") {
            await fx.replace(table)
        }
        signalState = await cache.read(SignalState.self, "signals.json") ?? SignalState()
    }

    private func persist() async {
        guard let cache else { return }
        for key in dirtyHistories { if let h = histories[key] { await cache.saveHistory(h) } }
        dirtyHistories.removeAll()
        await cache.write(quotes, "quotes.json")
        if let s = await symbols.takeDirty() { await cache.write(s, "symbols.json") }
        await cache.write(await fx.current(), "fx.json")
        await cache.write(signalState, "signals.json")
    }

    /// Drops cached data of a listing so it is fetched fresh (e.g. after changing the venue).
    public func reset(listingKey: String) async {
        histories[listingKey] = nil
        quotes[listingKey] = nil
        status[listingKey] = nil
        lastQuoteAttempt[listingKey] = nil
        lastHistoryAttempt[listingKey] = nil
        await symbols.remove(listingKey: listingKey)
        await cache?.removeHistory(listingKey)
    }

    public func resetAll() async {
        histories = [:]
        quotes = [:]
        status = [:]
        lastQuoteAttempt = [:]
        lastHistoryAttempt = [:]
        await router.health.reset()
        await cache?.clearAll()
    }

    public func forget(position: UUID) { signalState.forget(position) }

    // MARK: Refresh

    private struct Job: Sendable {
        var ref: SecurityRef
        var exchange: Exchange
        var history: Bool
        var historyFrom: DayKey
        var quote: Bool
    }

    public func desiredStart(_ rules: RuleSet) -> DayKey {
        // Trading days to calendar days: about 1.45, plus a safety margin.
        let runUp = Int(Double(rules.maxLength) * 1.5) + 20
        return DayKey.today(in: .berlin).adding(days: -(historyYears * 366 + runUp))
    }

    /// Updates quotes and histories that are due (or everything when `force`).
    public func refresh(depot: DepotFile, keys: [ProviderID: String], force: Bool = false, only: Set<UUID>? = nil,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async -> RefreshSummary {
        var summary = RefreshSummary()
        let catalog = depot.catalog
        let env = ProviderEnvironment(http: http, keys: keys, catalog: catalog)
        let wantFrom = desiredStart(depot.rules)
        let now = Date()

        var seen = Set<String>()
        var jobs: [Job] = []
        for p in depot.positions {
            if let only, !only.contains(p.id) { continue }
            let key = p.listing.key
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard let ex = catalog[p.listing.exchangeID] else {
                var s = status[key] ?? ListingStatus()
                s.lastError = "Unbekannte Börse \(p.listing.exchangeID)"
                status[key] = s
                continue
            }
            let h = histories[key]
            var needH = false
            var from = wantFrom
            if let h, !h.bars.isEmpty {
                if h.coveredFrom > wantFrom.adding(days: 10) {
                    needH = true
                } else if let last = h.lastDay, last < ex.lastCompletedSession(at: now) {
                    let since = now.timeIntervalSince(lastHistoryAttempt[key] ?? .distantPast)
                    if since > (force ? 120 : 1800) {
                        needH = true
                        from = last.adding(days: -7)
                    }
                }
            } else {
                needH = now.timeIntervalSince(lastHistoryAttempt[key] ?? .distantPast) > (force ? 60 : 900)
            }
            var needQ = force
            if !needQ {
                let lastTry = lastQuoteAttempt[key] ?? .distantPast
                if let q = quotes[key] {
                    if ex.isOpen(at: now) {
                        needQ = now.timeIntervalSince(q.fetchedAt) >= quoteInterval - 5 && now.timeIntervalSince(lastTry) >= quoteInterval - 5
                    } else {
                        let close = ProviderUtil.closeTime(ex.lastCompletedSession(at: now), ex)
                        needQ = q.time < close.addingTimeInterval(-60) && now.timeIntervalSince(lastTry) > 1200
                    }
                } else {
                    needQ = now.timeIntervalSince(lastTry) > 300
                }
            } else {
                needQ = now.timeIntervalSince(lastQuoteAttempt[key] ?? .distantPast) > 20
            }
            if needH || needQ {
                jobs.append(Job(ref: SecurityRef(p), exchange: ex, history: needH, historyFrom: from, quote: needQ))
            }
        }

        let total = jobs.count
        var done = 0
        progress?(0, total)
        for j in jobs {
            var s = status[j.ref.listing.key] ?? ListingStatus()
            s.isLoading = true
            status[j.ref.listing.key] = s
        }

        // Run listing jobs in parallel; the providers' own gates keep each API polite.
        await withTaskGroup(of: (String, JobResult).self) { group in
            var it = jobs.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let j = it.next() else { return false }
                group.addTask { [router, symbols, prefs = depot.sources] in
                    (j.ref.listing.key, await Self.run(j, router: router, prefs: prefs, env: env, symbols: symbols))
                }
                return true
            }
            while running < 8, addNext() { running += 1 }
            for await (key, result) in group {
                apply(result, key: key, summary: &summary)
                done += 1
                progress?(done, total)
                if !addNext() { running -= 1 }
            }
        }

        // Exchange rates for every currency in use.
        let currencies = Set(depot.positions.compactMap { histories[$0.listing.key]?.currency ?? catalog[$0.listing.exchangeID]?.currency })
        await fx.ensure(currencies, from: wantFrom)
        await fillNonECB(currencies, from: wantFrom, env: env)

        // Signals.
        fxTableSync = await fx.current()
        let snap = snapshotMetrics(depot: depot)
        for p in depot.positions {
            guard let m = snap[p.id], let ex = catalog[p.listing.exchangeID] else { continue }
            summary.events += signalState.process(metrics: m, position: p, exchange: ex, rules: depot.rules)
        }
        lastRefresh = Date()
        summary.finishedAt = Date()
        await persist()
        return summary
    }

    private struct JobResult: Sendable {
        var history: HistoryResult?
        var historyFrom: DayKey
        var historyAttempts: [DataRouter.Attempt] = []
        var quote: Quote?
        var quoteAttempts: [DataRouter.Attempt] = []
        var wantedHistory: Bool
        var wantedQuote: Bool
    }

    private static func run(_ j: Job, router: DataRouter, prefs: SourcePreferences, env: ProviderEnvironment, symbols: SymbolCache) async -> JobResult {
        var r = JobResult(historyFrom: j.historyFrom, wantedHistory: j.history, wantedQuote: j.quote)
        let ex = j.exchange
        if j.history {
            let from = j.historyFrom
            let o = await router.first(.history, what: "history", ref: j.ref, exchange: ex, prefs: prefs, env: env, symbols: symbols) { p, sym in
                try await p.history(symbol: sym, exchange: ex, from: from, env: env)
            }
            r.history = o.value
            r.historyAttempts = o.attempts
        }
        if j.quote {
            let o = await router.first(.quote, what: "quote", ref: j.ref, exchange: ex, prefs: prefs, env: env, symbols: symbols) { p, sym in
                try await p.quote(symbol: sym, exchange: ex, env: env)
            }
            r.quote = o.value
            r.quoteAttempts = o.attempts
        }
        return r
    }

    private func apply(_ r: JobResult, key: String, summary: inout RefreshSummary) {
        var s = status[key] ?? ListingStatus()
        s.isLoading = false
        var errors: [String] = []
        if r.wantedHistory {
            lastHistoryAttempt[key] = Date()
            if let h = r.history, !h.bars.isEmpty {
                if var existing = histories[key], existing.currency == h.currency, r.historyFrom > (existing.bars.first?.day ?? r.historyFrom) {
                    existing.merge(h.bars, source: h.source)
                    histories[key] = existing
                } else {
                    histories[key] = PriceHistory(listingKey: key, currency: h.currency, bars: h.bars, source: h.source, coveredFrom: r.historyFrom)
                }
                dirtyHistories.insert(key)
                s.historySource = h.source
                summary.historiesUpdated += 1
            } else {
                errors.append("Verlauf: " + Self.describe(r.historyAttempts))
                summary.failures += 1
            }
        }
        if r.wantedQuote {
            lastQuoteAttempt[key] = Date()
            if let q = r.quote {
                quotes[key] = q
                s.quoteSource = q.source
                summary.quotesUpdated += 1
            } else {
                errors.append("Kurs: " + Self.describe(r.quoteAttempts))
                summary.failures += 1
            }
        }
        s.attempts = r.historyAttempts + r.quoteAttempts
        s.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        s.updatedAt = Date()
        status[key] = s
    }

    static func describe(_ attempts: [DataRouter.Attempt]) -> String {
        if attempts.isEmpty { return "keine passende Datenquelle für diese Börse aktiv" }
        return attempts.map { "\($0.provider.displayName): \($0.error ?? "ok")" }.joined(separator: "; ")
    }

    /// Currencies the ECB does not publish come from Yahoo ("EURXXX=X").
    private func fillNonECB(_ currencies: Set<String>, from: DayKey, env: ProviderEnvironment) async {
        let table = await fx.current()
        for c in currencies where c != "EUR" && !CurrencyNormalizer.ecb.contains(c) {
            if let latest = table.latestDay(c), latest >= DayKey.today(in: .berlin).adding(days: -3) { continue }
            guard let yahoo = router.registry[.yahoo] as? YahooProvider, let ex = env.catalog["XETR"] else { continue }
            if let h = try? await yahoo.history(symbol: "EUR\(c)=X", exchange: ex, from: from, env: env) {
                await fx.merge(c, Dictionary(h.bars.map { ($0.day, $0.close) }, uniquingKeysWith: { a, _ in a }))
            }
        }
    }

    // MARK: Evaluation

    private func priceData(_ key: String) -> (bars: [Bar], quote: Quote?, currency: String?) {
        let h = histories[key]
        return (h?.bars ?? [], quotes[key], h?.currency ?? quotes[key]?.currency)
    }

    /// Converts a quote into the history currency if a provider reported another one.
    private func aligned(_ q: Quote?, to currency: String, table: FXTable) -> Quote? {
        guard var q, q.currency != currency else { return q }
        let day = DayKey.today(in: .berlin)
        guard let a = table.eurPerUnit(q.currency, day), let b = table.eurPerUnit(currency, day), b > 0 else { return nil }
        q.price = q.price * a / b
        q.previousClose = q.previousClose.map { $0 * a / b }
        q.currency = currency
        return q
    }

    private func snapshotMetrics(depot: DepotFile) -> [UUID: PositionMetrics] {
        var out: [UUID: PositionMetrics] = [:]
        let catalog = depot.catalog
        let table = fxTableSync
        for p in depot.positions {
            guard let ex = catalog[p.listing.exchangeID] else { continue }
            let d = priceData(p.listing.key)
            let cur = d.currency ?? p.listing.currency ?? ex.currency
            let q = aligned(d.quote, to: cur, table: table)
            out[p.id] = Evaluator.evaluate(position: p, exchange: ex, history: d.bars, quote: q, currency: cur, rules: depot.rules, fx: table.lookup)
        }
        return out
    }

    /// Last FX table copied into the actor for synchronous evaluation.
    private var fxTableSync = FXTable()

    public func snapshot(depot: DepotFile) async -> EngineSnapshot {
        fxTableSync = await fx.current()
        let m = snapshotMetrics(depot: depot)
        return EngineSnapshot(metrics: m, status: status, fx: fxTableSync, health: await router.health.snapshot(),
                              lastRefresh: lastRefresh, eventLog: signalState.log)
    }

    public func chart(position p: Position, depot: DepotFile, from: DayKey, lines: [LineSpec]) async -> [Evaluator.ChartPoint] {
        guard let ex = depot.catalog[p.listing.exchangeID] else { return [] }
        let table = await fx.current()
        let d = priceData(p.listing.key)
        let cur = d.currency ?? ex.currency
        return Evaluator.chart(history: d.bars, quote: aligned(d.quote, to: cur, table: table), exchange: ex, currency: cur,
                               lines: lines, from: from, fx: table.lookup)
    }

    public func history(_ key: String) -> PriceHistory? { histories[key] }
    public func quote(_ key: String) -> Quote? { quotes[key] }

    /// Search across providers for the "add security" dialog.
    public func search(_ query: String, depot: DepotFile, keys: [ProviderID: String]) async -> [SearchCandidate] {
        let env = ProviderEnvironment(http: http, keys: keys, catalog: depot.catalog)
        return await router.search(query, prefs: depot.sources, env: env)
    }

    /// Sends a test message to ntfy.
    public func sendTestPush(_ settings: NotificationSettings) async throws {
        try await NtfyNotifier(settings: settings, http: http).send(title: "Watchdog", body: "Test: Mitteilungen von Watchdog kommen an.", severity: .info)
    }

    public func push(_ events: [SignalEvent], settings: NotificationSettings) async {
        guard settings.ntfyEnabled else { return }
        let n = NtfyNotifier(settings: settings, http: http)
        for e in events { try? await n.send(e) }
    }
}

extension FXService {
    func replace(_ t: FXTable) {
        for (c, v) in t.rates { merge(c, v) }
    }
}
