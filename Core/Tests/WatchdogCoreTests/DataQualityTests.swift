import XCTest
@testable import WatchdogCore

final class FreshnessTests: XCTestCase {
    let xetra = ExchangeCatalog()["XETR"]!
    let tokyo = ExchangeCatalog()["XTKS"]!

    func berlin(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .berlin
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func quote(time: Date, fetched: Date) -> Quote {
        Quote(price: 100, time: time, previousClose: 99, currency: "EUR", source: .yahoo, fetchedAt: fetched)
    }

    func check(_ q: Quote?, lastBar: DayKey? = DayKey(iso: "2026-10-13"), now: Date, exchange: Exchange? = nil,
               currency: String = "EUR", fx: DayKey? = nil, status: ListingStatus? = nil) -> Freshness {
        FreshnessCheck.evaluate(exchange: exchange ?? xetra, quote: q, lastBarDay: lastBar, status: status, currency: currency,
                                fxLatest: fx, interval: 15 * 60, now: now)
    }

    func testOpenMarketFreshQuoteIsOK() {
        let now = berlin(2026, 10, 14, 12)
        XCTAssertEqual(check(quote(time: berlin(2026, 10, 14, 11, 45), fetched: berlin(2026, 10, 14, 11, 50)), now: now).level, .ok)
    }

    func testOpenMarketWithoutUpdatesIsStale() {
        let now = berlin(2026, 10, 14, 12)
        let f = check(quote(time: berlin(2026, 10, 14, 10, 20), fetched: berlin(2026, 10, 14, 10, 30)), now: now)
        XCTAssertEqual(f.level, .stale)
        XCTAssertTrue(f.headline.contains("keine Kurse"))
    }

    func testJustOpenedGetsGracePeriod() {
        let now = berlin(2026, 10, 14, 9, 20)
        let f = check(quote(time: berlin(2026, 10, 13, 17, 30), fetched: berlin(2026, 10, 13, 18)), now: now)
        XCTAssertEqual(f.level, .ok)
    }

    func testOnlyYesterdaysPriceWhileOpenIsNoTradeToday() {
        // Fetching works (fetched 5 minutes ago) but the price is from yesterday, e.g. a close-only source.
        let now = berlin(2026, 10, 14, 14)
        let f = check(quote(time: berlin(2026, 10, 13, 17, 30), fetched: berlin(2026, 10, 14, 13, 55)), now: now)
        XCTAssertEqual(f.level, .noTradeToday)
        XCTAssertFalse(f.isProblem)
    }

    func testClosingPriceMissingIsStale() {
        let now = berlin(2026, 10, 14, 22)
        let f = check(quote(time: berlin(2026, 10, 13, 17, 30), fetched: berlin(2026, 10, 13, 18)), now: now)
        XCTAssertEqual(f.level, .stale)
    }

    func testNoTradeButSourceAnswersIsNotAProblem() {
        let now = berlin(2026, 10, 14, 22)
        let f = check(quote(time: berlin(2026, 10, 13, 17, 30), fetched: berlin(2026, 10, 14, 21)), now: now)
        XCTAssertEqual(f.level, .noTradeToday)
    }

    func testClosingPriceCapturedIsOK() {
        let now = berlin(2026, 10, 14, 22)
        XCTAssertEqual(check(quote(time: berlin(2026, 10, 14, 17, 30), fetched: berlin(2026, 10, 14, 17, 45)), now: now).level, .ok)
    }

    func testWeekendIsOK() {
        let now = berlin(2026, 10, 17, 15)
        let f = check(quote(time: berlin(2026, 10, 16, 17, 30), fetched: berlin(2026, 10, 16, 17, 40)), lastBar: DayKey(iso: "2026-10-16"), now: now)
        XCTAssertEqual(f.level, .ok)
    }

    func testHistoryGapIsStale() {
        let now = berlin(2026, 10, 14, 22)
        let f = check(quote(time: berlin(2026, 10, 14, 17, 30), fetched: berlin(2026, 10, 14, 17, 45)), lastBar: DayKey(iso: "2026-10-08"), now: now)
        XCTAssertEqual(f.level, .stale)
        XCTAssertTrue(f.headline.contains("Verlauf"))
    }

    func testMissingExchangeRateIsStale() {
        let now = berlin(2026, 10, 14, 22)
        let q = Quote(price: 3000, time: berlin(2026, 10, 14, 8, 30), previousClose: 2990, currency: "JPY", source: .ft, fetchedAt: berlin(2026, 10, 14, 9))
        let f = check(q, lastBar: DayKey(iso: "2026-10-14"), now: now, exchange: tokyo, currency: "JPY", fx: nil)
        XCTAssertEqual(f.level, .stale)
        XCTAssertTrue(f.headline.contains("Wechselkurs"))
        let ok = check(q, lastBar: DayKey(iso: "2026-10-14"), now: now, exchange: tokyo, currency: "JPY", fx: DayKey(iso: "2026-10-14"))
        XCTAssertEqual(ok.level, .ok)
    }

    func testNothingLoadedYet() {
        let now = berlin(2026, 10, 14, 12)
        XCTAssertEqual(check(nil, lastBar: nil, now: now).level, .pending)
        var s = ListingStatus()
        s.lastQuoteAttempt = now
        s.lastError = "Kurs: Yahoo Finance: Gedrosselt"
        let f = check(nil, lastBar: nil, now: now, status: s)
        XCTAssertEqual(f.level, .missing)
        XCTAssertTrue(f.detail.contains("Gedrosselt"))
    }
}

final class OutageTests: XCTestCase {
    func testOneMessagePerDayAfterTwentyMinutes() {
        var s = SignalState()
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        let quiet = [(name: "Cameco", headline: "seit 10:15 keine Kurse")]
        XCTAssertNil(s.processOutage(quiet, enabled: true, now: t0))
        XCTAssertNil(s.processOutage(quiet, enabled: true, now: t0.addingTimeInterval(600)))
        let e = s.processOutage(quiet, enabled: true, now: t0.addingTimeInterval(1300))
        XCTAssertNotNil(e)
        XCTAssertTrue(e!.body.contains("Cameco"))
        XCTAssertFalse(e!.body.contains("\u{2013}"))
        XCTAssertNil(s.processOutage(quiet, enabled: true, now: t0.addingTimeInterval(2600)), "only once per day")
        XCTAssertNil(s.processOutage([], enabled: true, now: t0.addingTimeInterval(2700)))
        XCTAssertNil(s.quietSince)
    }

    func testDisabled() {
        var s = SignalState()
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        _ = s.processOutage([(name: "A", headline: "x")], enabled: false, now: t0)
        XCTAssertNil(s.processOutage([(name: "A", headline: "x")], enabled: false, now: t0.addingTimeInterval(3600)))
    }
}

/// A scripted provider for offline tests.
final class FakeProvider: MarketDataProvider, @unchecked Sendable {
    let id: ProviderID
    let capabilities: ProviderCapabilities = [.quote, .history]
    let gate = RequestGate(maxConcurrent: 4, minInterval: 0)
    var price: Double?
    var bars: [Bar]

    init(_ id: ProviderID, price: Double?, bars: [Bar]) {
        self.id = id
        self.price = price
        self.bars = bars
    }

    func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String { "X" }

    func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        guard let p = price else { throw ProviderError.notFound("fake") }
        return Quote(price: p, time: Date(), previousClose: bars.last?.close, currency: "EUR", source: id)
    }

    func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        HistoryResult(bars: bars, currency: "EUR", source: id)
    }
}

final class PlausibilityTests: XCTestCase {
    func bars() -> [Bar] {
        var out: [Bar] = []
        var d = DayKey.today(in: .berlin).adding(days: -400)
        while d < DayKey.today(in: .berlin).adding(days: -1) {
            if d.weekday != 1 && d.weekday != 7 { out.append(Bar(day: d, close: 100)) }
            d = d.adding(days: 1)
        }
        return out
    }

    func run(primary: Double?, second: Double?) async -> (Quote?, ListingStatus?) {
        let a = FakeProvider(.yahoo, price: primary, bars: bars())
        let b = FakeProvider(.onvista, price: second, bars: bars())
        let engine = MarketEngine(cacheDir: nil, router: DataRouter(registry: ProviderRegistry([a, b])))
        let p = Position(name: "Test", isin: "DE0000000001", listing: Listing(exchangeID: "XETR", ticker: "TST"))
        let depot = DepotFile(positions: [p])
        _ = await engine.refresh(depot: depot, keys: [:], force: true)
        let snap = await engine.snapshot(depot: depot)
        return (await engine.quote(p.listing.key), snap.status[p.listing.key])
    }

    func testNormalMoveNeedsNoConfirmation() async {
        let (q, s) = await run(primary: 105, second: 105)
        XCTAssertEqual(q?.price, 105)
        XCTAssertFalse(q?.suspect ?? true)
        XCTAssertNil(s?.plausibilityNote)
    }

    func testConfirmedJump() async {
        let (q, s) = await run(primary: 150, second: 151)
        XCTAssertEqual(q?.price, 150)
        XCTAssertEqual(q?.confirmedBy, .onvista)
        XCTAssertFalse(q?.suspect ?? true)
        XCTAssertNotNil(s?.plausibilityNote)
    }

    func testWrongTickIsReplaced() async {
        let (q, s) = await run(primary: 1000, second: 101)
        XCTAssertEqual(q?.price, 101)
        XCTAssertEqual(q?.source, .onvista)
        XCTAssertTrue(s?.plausibilityNote?.contains("verwendet") ?? false)
    }

    func testUnconfirmedJumpIsSuspect() async {
        let (q, _) = await run(primary: 40, second: nil)
        XCTAssertEqual(q?.price, 40)
        XCTAssertTrue(q?.suspect ?? false)
    }

    func testSuspectQuoteDoesNotFireCrossing() {
        let ex = ExchangeCatalog()["XETR"]!
        var b: [Bar] = []
        var d = DayKey(iso: "2025-01-02")!
        var price = 100.0
        while b.count < 260 {
            if d.weekday != 1 && d.weekday != 7 { price += 0.2; b.append(Bar(day: d, close: price)) }
            d = d.adding(days: 1)
        }
        let p = Position(name: "T", listing: Listing(exchangeID: "XETR", ticker: "T"))
        let next = b.last!.day.adding(days: 3)
        var q = Quote(price: 50, time: next.date, previousClose: b.last!.close, currency: "EUR", source: .yahoo)
        q.suspect = true
        let m = Evaluator.evaluate(position: p, exchange: ex, history: b, quote: q, currency: "EUR", rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m.ampel.state, .red, "the display still shows where the price is")
        XCTAssertFalse(m.hits.contains { $0.rule.id == RuleSet.crossDownID }, "but no alarm from an unconfirmed jump")
        q.suspect = false
        let m2 = Evaluator.evaluate(position: p, exchange: ex, history: b, quote: q, currency: "EUR", rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertTrue(m2.hits.contains { $0.rule.id == RuleSet.crossDownID })
    }
}

final class HeartbeatSettingsTests: XCTestCase {
    func testURLValidation() {
        var n = NotificationSettings()
        XCTAssertNil(n.heartbeat)
        n.heartbeatURL = "  https://hc-ping.com/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b \n"
        XCTAssertEqual(n.heartbeat?.host, "hc-ping.com")
        n.heartbeatURL = "hc-ping.com/abc"
        XCTAssertNil(n.heartbeat)
        n.heartbeatURL = "ftp://example.com/x"
        XCTAssertNil(n.heartbeat)
    }

    func testOldFilesDecode() throws {
        let old = #"{"macEnabled":true,"ntfyEnabled":true,"ntfyServer":"https://ntfy.sh","ntfyTopic":"watchdog-abc"}"#
        let n = try JSONDecoder().decode(NotificationSettings.self, from: Data(old.utf8))
        XCTAssertTrue(n.dataAlerts)
        XCTAssertNil(n.heartbeatURL)
        var m = n
        m.heartbeatURL = "https://hc-ping.com/x"
        let back = try JSONDecoder().decode(NotificationSettings.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.heartbeatURL, "https://hc-ping.com/x")
    }
}

final class FXUsageTests: XCTestCase {
    /// JPY bars with a rate that changes every day: each chart point must use its own day's rate,
    /// today's value the live market rate.
    func testEachDayUsesItsOwnRateAndTodayTheLiveRate() {
        let ex = ExchangeCatalog()["XTKS"]!
        var bars: [Bar] = []
        var rates: [DayKey: Double] = [:]
        var d = DayKey(iso: "2025-01-06")!
        var i = 0
        while bars.count < 260 {
            if d.weekday != 1 && d.weekday != 7 {
                bars.append(Bar(day: d, close: 3000 + Double(i)))
                rates[d] = 1 / (150 + Double(i) * 0.1)   // EUR per JPY, different every day
                i += 1
            }
            d = d.adding(days: 1)
        }
        let fx: FXLookup = { _, day in rates[day] }
        let p = Position(name: "T", listing: Listing(exchangeID: "XTKS", ticker: "7203"), lots: [Lot(day: bars[0].day, quantity: 100, totalCostEUR: 1000)])
        let live = 1 / 180.0
        let m = Evaluator.evaluate(position: p, exchange: ex, history: bars, quote: nil, currency: "JPY", rules: RuleSet(), fx: fx, liveRate: live)
        XCTAssertEqual(m.priceEUR!, bars.last!.close * live, accuracy: 1e-9)
        XCTAssertTrue(m.fxLive)
        let pts = Evaluator.chart(history: bars, quote: nil, exchange: ex, currency: "JPY", lines: [.sma(38)], from: bars[0].day, fx: fx, liveRate: live)
        for (k, pt) in pts.enumerated().dropLast() {
            XCTAssertEqual(pt.priceEUR, bars[k].close * rates[bars[k].day]!, accuracy: 1e-9, "day \(pt.day.iso)")
            if let l = pt.lines[.sma(38)], let ll = pt.linesLocal[.sma(38)] { XCTAssertEqual(l, ll * rates[bars[k].day]!, accuracy: 1e-9) }
        }
        XCTAssertEqual(pts.last!.priceEUR, bars.last!.close * live, accuracy: 1e-9)
        XCTAssertEqual(pts.last!.priceLocal, bars.last!.close)
        // Without a live rate the newest ECB rate is used.
        let m2 = Evaluator.evaluate(position: p, exchange: ex, history: bars, quote: nil, currency: "JPY", rules: RuleSet(), fx: fx)
        XCTAssertEqual(m2.priceEUR!, bars.last!.close * rates[bars.last!.day]!, accuracy: 1e-9)
        XCTAssertFalse(m2.fxLive)
    }
}
