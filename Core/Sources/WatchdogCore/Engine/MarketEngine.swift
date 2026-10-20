import Foundation

public struct ListingStatus: Sendable {
    public var historySource: ProviderID?
    public var quoteSource: ProviderID?
    public var lastError: String?
    public var attempts: [DataRouter.Attempt] = []
    public var updatedAt: Date?
    public var isLoading = false
    public var lastQuoteAttempt: Date?
    public var lastQuoteSuccess: Date?
    public var quoteFailures = 0
    public var lastHistorySuccess: Date?
    public var historyFailures = 0
    /// Set when a large price jump could not be confirmed by a second source, or was replaced by it.
    public var plausibilityNote: String?

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
    /// Data freshness per listing key.
    public var freshness: [String: Freshness]
    /// Current market exchange rates per currency (when available).
    public var liveFX: [String: LiveFX]
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
        /// Last completed close before today, used to spot implausible jumps.
        var refClose: Double?
    }

    /// A move larger than this (relative to the previous close) must be confirmed by a second source.
    public static func jumpThreshold(_ e: Exchange) -> Double { e.kind == .crypto ? 0.25 : 0.20 }

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
                let todayLocal = DayKey(date: now, timeZone: ex.tz)
                let refClose = h?.bars.last(where: { $0.day < todayLocal })?.close
                jobs.append(Job(ref: SecurityRef(p), exchange: ex, history: needH, historyFrom: from, quote: needQ, refClose: refClose))
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
        await refreshLiveFX(currencies, env: env, force: force)

        // Signals.
        fxTableSync = await fx.current()
        let snap = snapshotMetrics(depot: depot)
        for p in depot.positions {
            guard let m = snap[p.id], let ex = catalog[p.listing.exchangeID] else { continue }
            summary.events += signalState.process(metrics: m, position: p, exchange: ex, rules: depot.rules)
        }

        // Sources that went quiet: one summary message per day, after the gap has lasted a while.
        if only == nil {
            let fresh = freshnessMap(depot: depot, now: Date())
            var seenKeys = Set<String>()
            let quiet: [(String, String)] = depot.positions.compactMap { p in
                guard let f = fresh[p.listing.key], f.isProblem, !seenKeys.contains(p.listing.key) else { return nil }
                seenKeys.insert(p.listing.key)
                return (p.name, f.headline)
            }
            if let e = signalState.processOutage(quiet, enabled: depot.notifications.dataAlerts) {
                summary.events.append(e)
            }
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
        var plausibilityNote: String?
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
            if let q = o.value {
                let checked = await verify(q, refClose: j.refClose, job: j, router: router, prefs: prefs, env: env, symbols: symbols)
                r.quote = checked.quote
                r.plausibilityNote = checked.note
            }
        }
        return r
    }

    /// Large jumps are double-checked with another source at the same venue. Unconfirmed jumps are kept for display
    /// but marked as suspect, so they do not fire alarms until a closing price confirms them.
    private static func verify(_ q: Quote, refClose: Double?, job j: Job, router: DataRouter, prefs: SourcePreferences,
                               env: ProviderEnvironment, symbols: SymbolCache) async -> (quote: Quote, note: String?) {
        guard let ref = q.previousClose ?? refClose, ref > 0 else { return (q, nil) }
        let move = q.price / ref - 1
        let limit = jumpThreshold(j.exchange)
        guard abs(move) > limit else { return (q, nil) }
        let ex = j.exchange
        let o = await router.first(.quote, what: "confirm", ref: j.ref, exchange: ex, prefs: prefs, env: env, symbols: symbols,
                                   excluding: [q.source]) { p, sym in
            try await p.quote(symbol: sym, exchange: ex, env: env)
        }
        let pct = Format.pct(move * 100, signed: true)
        var out = q
        if let c = o.value, c.currency == q.currency,
           DayKey(date: c.time, timeZone: ex.tz) == DayKey(date: q.time, timeZone: ex.tz) {
            if abs(c.price / q.price - 1) < 0.04 {
                out.confirmedBy = c.source
                return (out, "Kurssprung \(pct) von \(c.source.displayName) bestätigt.")
            }
            if abs(c.price / ref - 1) <= limit {
                return (c, "\(q.source.displayName) meldete \(pct), \(c.source.displayName) nicht; Kurs von \(c.source.displayName) verwendet.")
            }
        }
        out.suspect = true
        return (out, "Kurssprung \(pct) laut \(q.source.displayName), von keiner zweiten Quelle bestätigt. Signale warten auf den Schlusskurs.")
    }

    private func apply(_ r: JobResult, key: String, summary: inout RefreshSummary) {
        var s = status[key] ?? ListingStatus()
        s.isLoading = false
        var errors: [String] = []
        if r.wantedHistory {
            lastHistoryAttempt[key] = Date()
            if let h = r.history, !h.bars.isEmpty {
                s.lastHistorySuccess = Date()
                s.historyFailures = 0
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
                s.historyFailures += 1
                errors.append("Verlauf: " + Self.describe(r.historyAttempts))
                summary.failures += 1
            }
        }
        if r.wantedQuote {
            lastQuoteAttempt[key] = Date()
            s.lastQuoteAttempt = Date()
            if let q = r.quote {
                quotes[key] = q
                s.quoteSource = q.source
                s.lastQuoteSuccess = Date()
                s.quoteFailures = 0
                s.plausibilityNote = r.plausibilityNote
                summary.quotesUpdated += 1
            } else {
                s.quoteFailures += 1
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

    /// Current market rates (Yahoo "EURJPY=X" and so on), at most as often as quotes are fetched.
    /// A rate that is more than 5 % away from the ECB rate is treated as an error and not used.
    private var liveFX: [String: LiveFX] = [:]

    private func refreshLiveFX(_ currencies: Set<String>, env: ProviderEnvironment, force: Bool) async {
        guard let yahoo = router.registry[.yahoo], let ex = env.catalog["XETR"] else { return }
        let table = await fx.current()
        let today = DayKey.today(in: .berlin)
        for c in currencies.sorted() where c != "EUR" {
            if !force, let l = liveFX[c], Date().timeIntervalSince(l.fetchedAt) < max(300, quoteInterval) { continue }
            guard let q = try? await yahoo.quote(symbol: "EUR\(c)=X", exchange: ex, env: env), q.price > 0 else { continue }
            let eurPerUnit = 1 / q.price
            if let ecb = table.eurPerUnit(c, today), abs(eurPerUnit / ecb - 1) > 0.05 { continue }
            liveFX[c] = LiveFX(eurPerUnit: eurPerUnit, time: q.time, source: .yahoo)
        }
    }

    /// A live rate is used while it is at most 6 hours old; otherwise the ECB rate applies.
    private func liveRate(_ currency: String) -> Double? {
        guard currency != "EUR", let l = liveFX[currency], Date().timeIntervalSince(l.fetchedAt) < 6 * 3600 else { return nil }
        return l.eurPerUnit
    }

    public func setLiveFX(_ currency: String, _ value: LiveFX?) { liveFX[currency] = value }

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
            out[p.id] = Evaluator.evaluate(position: p, exchange: ex, history: d.bars, quote: q, currency: cur, rules: depot.rules, fx: table.lookup,
                                           liveRate: liveRate(cur))
        }
        return out
    }

    /// Last FX table copied into the actor for synchronous evaluation.
    private var fxTableSync = FXTable()

    public func snapshot(depot: DepotFile) async -> EngineSnapshot {
        fxTableSync = await fx.current()
        let m = snapshotMetrics(depot: depot)
        return EngineSnapshot(metrics: m, status: status, fx: fxTableSync, health: await router.health.snapshot(),
                              lastRefresh: lastRefresh, eventLog: signalState.log, freshness: freshnessMap(depot: depot, now: Date()),
                              liveFX: liveFX.filter { Date().timeIntervalSince($0.value.fetchedAt) < 6 * 3600 })
    }

    private func freshnessMap(depot: DepotFile, now: Date) -> [String: Freshness] {
        var out: [String: Freshness] = [:]
        let catalog = depot.catalog
        for p in depot.positions where out[p.listing.key] == nil {
            guard let ex = catalog[p.listing.exchangeID] else { continue }
            let key = p.listing.key
            let cur = histories[key]?.currency ?? quotes[key]?.currency ?? ex.currency
            out[key] = FreshnessCheck.evaluate(exchange: ex, quote: quotes[key], lastBarDay: histories[key]?.lastDay, status: status[key],
                                               currency: cur, fxLatest: fxTableSync.latestDay(cur), interval: quoteInterval, now: now)
        }
        return out
    }

    public func chart(position p: Position, depot: DepotFile, from: DayKey, lines: [LineSpec]) async -> [Evaluator.ChartPoint] {
        guard let ex = depot.catalog[p.listing.exchangeID] else { return [] }
        let table = await fx.current()
        let d = priceData(p.listing.key)
        let cur = d.currency ?? ex.currency
        return Evaluator.chart(history: d.bars, quote: aligned(d.quote, to: cur, table: table), exchange: ex, currency: cur,
                               lines: lines, from: from, fx: table.lookup, liveRate: liveRate(cur))
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

    /// Euro per unit of `currency` on `day` (ECB reference rate, previous business day if needed).
    public func eurRate(_ currency: String, on day: DayKey) async -> Double? {
        if currency == "EUR" { return 1 }
        _ = await fx.ensure([currency], from: day.adding(days: -14))
        return await fx.current().eurPerUnit(currency, day)
    }

    /// Calls the heartbeat URL. Returns nil on success or a short error text.
    public func heartbeat(_ url: URL) async -> String? {
        do {
            let (data, resp) = try await http.get(url)
            try HTTPClient.check(resp, data)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
