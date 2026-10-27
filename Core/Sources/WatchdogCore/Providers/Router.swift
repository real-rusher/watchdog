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
        /// The source answered, but only with data older than expected.
        public var outdated = false

        public init(provider: ProviderID, error: String?, outdated: Bool = false) {
            self.provider = provider
            self.error = error
            self.outdated = outdated
        }
    }

    /// How current an answer is.
    public enum Verdict: Sendable {
        case current
        /// Older than expected; the text says how old ("Stand 15.10.").
        case outdated(String)
    }

    /// A stored symbol named another company or nothing; the ISIN led to another one that works.
    public struct SymbolRepair: Sendable {
        public var provider: ProviderID
        public var oldSymbol: String
        public var newSymbol: String
        /// Company the old symbol delivered, nil if it delivered nothing.
        public var wrongCompany: String?
    }

    /// A source delivered another company under the stored symbol.
    public struct WrongCompany: Sendable {
        public var provider: ProviderID
        public var symbol: String
        public var name: String
    }

    public struct Outcome<T: Sendable>: Sendable {
        public var value: T?
        public var attempts: [Attempt]
        /// Source and symbol of `value`.
        public var provider: ProviderID?
        public var symbol: String?
        /// The answer's company name matches the security (or the ISIN confirmed the symbol).
        public var nameConfirmed = false
        /// `value` is older than expected because no source had anything newer.
        public var outdated = false
        public var repair: SymbolRepair?
        public var wrongCompany: [WrongCompany] = []

        public init(value: T?, attempts: [Attempt]) {
            self.value = value
            self.attempts = attempts
        }
    }

    /// Runs `body` against each candidate until one delivers current data.
    ///
    /// An answer `judge` rates as outdated does not end the search: the next sources are asked, and if none has anything
    /// current the newest answer (by `newer`) is returned. An answer for another company is never used.
    public func first<T: Sendable>(_ cap: ProviderCapabilities, what: String, ref: SecurityRef, exchange: Exchange, prefs: SourcePreferences,
                                   env: ProviderEnvironment, symbols: SymbolCache?, excluding: Set<ProviderID> = [],
                                   judge: (@Sendable (T) -> Verdict)? = nil, newer: (@Sendable (T, T) -> Bool)? = nil,
                                   _ body: @Sendable (MarketDataProvider, String) async throws -> T) async -> Outcome<T> {
        var attempts: [Attempt] = []
        var best: Outcome<T>?
        var wrong: [WrongCompany] = []
        let list = candidates(cap, exchange: exchange, listing: ref.listing, prefs: prefs, keys: env.keys).filter { !excluding.contains($0) }
        // A confirmation request always looks at every other source, even without automatic fallback.
        let tryList = (prefs.autoFallback || !excluding.isEmpty) ? list : Array(list.prefix(1))
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
            let key = ref.listing.key
            var sym = ""
            var answer: Checked<T>
            do {
                if let cached = await symbols?.get(key, pid) {
                    sym = cached
                } else {
                    sym = try await p.resolveSymbol(ref, exchange: exchange, env: env)
                    await symbols?.put(key, pid, sym)
                }
                answer = try await checked(p, sym, ref: ref, exchange: exchange, env: env, symbols: symbols, body)
                if case .wrong(let name) = answer {
                    answer = await repaired(p, sym, ref: ref, exchange: exchange, env: env, symbols: symbols, wrongName: name, body)
                    // The ISIN confirming the same symbol means the names merely differ ("Google", "Alphabet Inc.").
                    if case .ok(_, _, nil) = answer {} else { wrong.append(WrongCompany(provider: pid, symbol: sym, name: name)) }
                    if case .failed = answer {
                        await symbols?.remove(key, pid)
                        await health.failure(pid, key, what, ProviderError.notFound("andere Firma"))
                        attempts.append(Attempt(provider: pid, error: "liefert unter \(sym) eine andere Firma (\(name))"))
                        continue
                    }
                }
            } catch {
                // An unknown or empty symbol may come from another venue: the ISIN can lead to the right one.
                var fixed: Checked<T> = .failed
                if let pe = error as? ProviderError, case .notFound = pe, !sym.isEmpty {
                    fixed = await repaired(p, sym, ref: ref, exchange: exchange, env: env, symbols: symbols, wrongName: nil, body)
                }
                guard case .ok = fixed else {
                    await health.failure(pid, key, what, error)
                    if let pe = error as? ProviderError, !pe.isProviderWide {
                        // The symbol may be stale; resolve it again next time.
                        await symbols?.remove(key, pid)
                    }
                    attempts.append(Attempt(provider: pid, error: String(describing: error)))
                    continue
                }
                answer = fixed
            }
            guard case .ok(let v, let confirmed, let repair) = answer else { continue }
            await health.success(pid)
            var o = Outcome(value: v, attempts: [])
            o.provider = pid
            o.symbol = repair?.newSymbol ?? sym
            o.nameConfirmed = confirmed
            o.repair = repair
            if case .outdated(let note)? = judge?(v) {
                attempts.append(Attempt(provider: pid, error: note, outdated: true))
                o.outdated = true
                if let b = best?.value, let newer, !newer(v, b) { continue }
                best = o
                continue
            }
            attempts.append(Attempt(provider: pid, error: nil))
            o.attempts = attempts
            o.wrongCompany = wrong
            return o
        }
        var out = best ?? Outcome(value: nil, attempts: [])
        out.attempts = attempts
        out.wrongCompany = wrong
        return out
    }

    private enum Checked<T: Sendable>: Sendable {
        case ok(T, confirmed: Bool, repair: SymbolRepair?)
        case wrong(String)
        case failed
    }

    /// Calls the provider and compares the company name of the answer with the security.
    private func checked<T: Sendable>(_ p: MarketDataProvider, _ sym: String, ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment,
                                      symbols: SymbolCache?, _ body: @Sendable (MarketDataProvider, String) async throws -> T) async throws -> Checked<T> {
        let v = try await body(p, sym)
        guard let name = (v as? NamedAnswer)?.instrumentName, !name.isEmpty else { return .ok(v, confirmed: false, repair: nil) }
        if await symbols?.isVerified(ref.listing.key, p.id, sym) == true { return .ok(v, confirmed: true, repair: nil) }
        switch Lenient.sameCompany(name, ref.name) {
        case true?: return .ok(v, confirmed: true, repair: nil)
        case false?: return .wrong(name)
        case nil: return .ok(v, confirmed: false, repair: nil)
        }
    }

    /// Looks the symbol up again through the ISIN. If that finds another symbol, it is tried and kept when it works.
    /// If the ISIN leads to the same symbol, the security is the right one after all (the names merely differ).
    private func repaired<T: Sendable>(_ p: MarketDataProvider, _ sym: String, ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment,
                                       symbols: SymbolCache?, wrongName: String?,
                                       _ body: @Sendable (MarketDataProvider, String) async throws -> T) async -> Checked<T> {
        guard let fresh = try? await p.symbolByISIN(ref, exchange: exchange, env: env), !fresh.isEmpty else { return .failed }
        let key = ref.listing.key
        if fresh == sym {
            guard wrongName != nil, let v = try? await body(p, sym) else { return .failed }
            await symbols?.markVerified(key, p.id, sym)
            return .ok(v, confirmed: true, repair: nil)
        }
        guard let answer = try? await checked(p, fresh, ref: ref, exchange: exchange, env: env, symbols: symbols, body),
              case .ok(let v, _, _) = answer else { return .failed }
        await symbols?.put(key, p.id, fresh)
        await symbols?.markVerified(key, p.id, fresh)
        return .ok(v, confirmed: true, repair: SymbolRepair(provider: p.id, oldSymbol: sym, newSymbol: fresh, wrongCompany: wrongName))
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

    /// The ISIN confirmed this symbol although the company names differ.
    public func markVerified(_ listingKey: String, _ p: ProviderID, _ symbol: String) {
        map["\(listingKey)|\(p.rawValue)|verified"] = symbol
        dirty = true
    }

    public func isVerified(_ listingKey: String, _ p: ProviderID, _ symbol: String) -> Bool {
        map["\(listingKey)|\(p.rawValue)|verified"] == symbol
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
