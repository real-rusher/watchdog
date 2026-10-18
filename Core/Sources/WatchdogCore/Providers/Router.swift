import Foundation

/// All providers by id.
public final class ProviderRegistry: @unchecked Sendable {
    public let providers: [ProviderID: MarketDataProvider]

    public init(_ list: [MarketDataProvider]? = nil) {
        let l = list ?? [
            YahooProvider(), OnVistaProvider(), FTProvider(), LSTCProvider(), TradegateProvider(), BitfinexProvider(),
            EODHDProvider(), TwelveDataProvider(), AlphaVantageProvider(), FinnhubProvider(),
        ]
        var map: [ProviderID: MarketDataProvider] = [:]
        for p in l { map[p.id] = p }
        self.providers = map
    }

    public subscript(_ id: ProviderID) -> MarketDataProvider? { providers[id] }
}

/// Remembers failures so a throttled provider is skipped for a while and a symbol a provider does not know is not retried constantly.
public actor ProviderHealth {
    public struct Status: Sendable {
        public var cooldownUntil: Date?
        public var lastError: String?
        public var lastSuccess: Date?
        public var successCount: Int
        public var failureCount: Int
    }

    private var status: [ProviderID: Status] = [:]
    private var symbolMisses: [String: Date] = [:]
    private var strikes: [ProviderID: Int] = [:]

    public init() {}

    public func isAvailable(_ p: ProviderID) -> Bool {
        guard let until = status[p]?.cooldownUntil else { return true }
        return until < Date()
    }

    public func missed(_ p: ProviderID, _ listingKey: String, _ what: String) -> Bool {
        guard let t = symbolMisses["\(p.rawValue)|\(listingKey)|\(what)"] else { return false }
        return Date().timeIntervalSince(t) < 6 * 3600
    }

    public func success(_ p: ProviderID) {
        var s = status[p] ?? Status(successCount: 0, failureCount: 0)
        s.lastSuccess = Date()
        s.successCount += 1
        s.cooldownUntil = nil
        status[p] = s
        strikes[p] = 0
    }

    public func failure(_ p: ProviderID, _ listingKey: String, _ what: String, _ error: Error) {
        var s = status[p] ?? Status(successCount: 0, failureCount: 0)
        s.failureCount += 1
        s.lastError = String(describing: error)
        if let pe = error as? ProviderError, pe.isProviderWide {
            let n = (strikes[p] ?? 0) + 1
            strikes[p] = n
            // 1, 2, 4, 8 ... up to 30 minutes.
            let minutes = min(30.0, pow(2.0, Double(n - 1)))
            if n >= 2 || { if case .throttled = pe { return true }; return false }() {
                s.cooldownUntil = Date().addingTimeInterval(minutes * 60)
            }
        } else {
            symbolMisses["\(p.rawValue)|\(listingKey)|\(what)"] = Date()
        }
        status[p] = s
    }

    public func snapshot() -> [ProviderID: Status] { status }

    public func reset() {
        status = [:]
        symbolMisses = [:]
        strikes = [:]
    }
}

/// Picks providers for a request and falls back along the configured order.
public struct DataRouter: Sendable {
    public let registry: ProviderRegistry
    public let health: ProviderHealth

    public init(registry: ProviderRegistry = ProviderRegistry(), health: ProviderHealth = ProviderHealth()) {
        self.registry = registry
        self.health = health
    }

    /// Ordered candidates for a capability at a venue.
    public func candidates(_ cap: ProviderCapabilities, exchange: Exchange, listing: Listing?, prefs: SourcePreferences, keys: [ProviderID: String]) -> [ProviderID] {
        var order = prefs.perExchange[exchange.id] ?? prefs.order
        for p in prefs.order where !order.contains(p) { order.append(p) }
        if let forced = listing?.preferredProvider {
            order.removeAll { $0 == forced }
            order.insert(forced, at: 0)
        }
        return order.filter { id in
            guard !prefs.disabled.contains(id), let p = registry[id], p.capabilities.contains(cap), p.supports(exchange) else { return false }
            if id.requiresKey && (keys[id]?.isEmpty ?? true) { return false }
            return true
        }
    }

    public struct Attempt: Sendable {
        public var provider: ProviderID
        public var error: String?
    }

    public struct Outcome<T: Sendable>: Sendable {
        public var value: T?
        public var attempts: [Attempt]
    }

    /// Runs `body` against each candidate until one succeeds.
    public func first<T: Sendable>(_ cap: ProviderCapabilities, what: String, ref: SecurityRef, exchange: Exchange, prefs: SourcePreferences,
                                   env: ProviderEnvironment, symbols: SymbolCache?,
                                   _ body: @Sendable (MarketDataProvider, String) async throws -> T) async -> Outcome<T> {
        var attempts: [Attempt] = []
        let list = candidates(cap, exchange: exchange, listing: ref.listing, prefs: prefs, keys: env.keys)
        let tryList = prefs.autoFallback ? list : Array(list.prefix(1))
        for pid in tryList {
            guard let p = registry[pid] else { continue }
            guard await health.isAvailable(pid) else {
                attempts.append(Attempt(provider: pid, error: "pausiert nach Fehlern"))
                continue
            }
            if await health.missed(pid, ref.listing.key, what) {
                attempts.append(Attempt(provider: pid, error: "kennt den Wert nicht"))
                continue
            }
            do {
                let sym: String
                if let cached = await symbols?.get(ref.listing.key, pid) {
                    sym = cached
                } else {
                    sym = try await p.resolveSymbol(ref, exchange: exchange, env: env)
                    await symbols?.put(ref.listing.key, pid, sym)
                }
                let v = try await body(p, sym)
                await health.success(pid)
                attempts.append(Attempt(provider: pid, error: nil))
                return Outcome(value: v, attempts: attempts)
            } catch {
                await health.failure(pid, ref.listing.key, what, error)
                if let pe = error as? ProviderError, !pe.isProviderWide {
                    // The symbol may be stale; resolve it again next time.
                    await symbols?.remove(ref.listing.key, pid)
                }
                attempts.append(Attempt(provider: pid, error: String(describing: error)))
            }
        }
        return Outcome(value: nil, attempts: attempts)
    }

    /// Searches several providers in parallel and merges the results.
    public func search(_ query: String, prefs: SourcePreferences, env: ProviderEnvironment, providers: [ProviderID]? = nil) async -> [SearchCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let reg = self.registry
        let ids = (providers ?? prefs.order).filter { id in
            guard !prefs.disabled.contains(id), let p = reg[id], p.capabilities.contains(.search) else { return false }
            // Twelve Data search works without a key.
            if id.requiresKey && id != .twelvedata && (env.keys[id]?.isEmpty ?? true) { return false }
            return true
        }
        let health = self.health
        return await withTaskGroup(of: [SearchCandidate].self) { group in
            for id in ids {
                group.addTask {
                    guard let p = reg[id] else { return [] }
                    do {
                        let r = try await p.search(q, env: env)
                        await health.success(id)
                        return r
                    } catch {
                        return []
                    }
                }
            }
            var all: [SearchCandidate] = []
            for await r in group { all += r }
            return all
        }
    }
}

/// Provider symbols that were resolved at runtime (persisted in the cache folder).
public actor SymbolCache {
    private var map: [String: String]
    private var dirty = false

    public init(_ initial: [String: String] = [:]) { self.map = initial }

    public func get(_ listingKey: String, _ p: ProviderID) -> String? { map["\(listingKey)|\(p.rawValue)"] }

    public func put(_ listingKey: String, _ p: ProviderID, _ symbol: String) {
        map["\(listingKey)|\(p.rawValue)"] = symbol
        dirty = true
    }

    public func remove(_ listingKey: String, _ p: ProviderID) {
        map["\(listingKey)|\(p.rawValue)"] = nil
        dirty = true
    }

    public func remove(listingKey: String) {
        map = map.filter { !$0.key.hasPrefix(listingKey + "|") }
        dirty = true
    }

    public func all() -> [String: String] { map }

    public func takeDirty() -> [String: String]? {
        guard dirty else { return nil }
        dirty = false
        return map
    }
}
