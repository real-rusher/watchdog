import XCTest
@testable import WatchdogCore

/// A provider with scripted answers per symbol, for the fallback and symbol repair tests.
final class ScriptedProvider: MarketDataProvider, @unchecked Sendable {
    struct Answer {
        var price: Double?
        var time: Date
        var name: String?
        var bars: [Bar]
    }

    let id: ProviderID
    let capabilities: ProviderCapabilities = [.quote, .history]
    let gate = RequestGate(maxConcurrent: 4, minInterval: 0)
    var answers: [String: Answer]
    /// What a lookup through the ISIN finds.
    var isinSymbol: String?
    private(set) var asked: [String] = []

    init(_ id: ProviderID, _ answers: [String: Answer], isinSymbol: String? = nil) {
        self.id = id
        self.answers = answers
        self.isinSymbol = isinSymbol
    }

    func resolveSymbol(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String {
        ref.listing.symbol(id) ?? ref.listing.ticker + (id == .yahoo ? exchange.code(.yahoo) ?? "" : "")
    }

    func symbolByISIN(_ ref: SecurityRef, exchange: Exchange, env: ProviderEnvironment) async throws -> String? {
        ref.isin == nil ? nil : isinSymbol
    }

    func quote(symbol: String, exchange: Exchange, env: ProviderEnvironment) async throws -> Quote {
        asked.append(symbol)
        guard let a = answers[symbol], let p = a.price else { throw ProviderError.notFound(symbol) }
        return Quote(price: p, time: a.time, previousClose: a.bars.last?.close, currency: "EUR", source: id, instrumentName: a.name)
    }

    func history(symbol: String, exchange: Exchange, from: DayKey, env: ProviderEnvironment) async throws -> HistoryResult {
        guard let a = answers[symbol], !a.bars.isEmpty else { throw ProviderError.notFound(symbol) }
        return HistoryResult(bars: a.bars, currency: "EUR", source: id, instrumentName: a.name)
    }
}

final class FallbackTests: XCTestCase {
    let now = Date()

    /// Weekday closes at 100 from 400 days back up to `end` days ago (0 = today, always current).
    func bars(endingDaysAgo end: Int) -> [Bar] {
        var out: [Bar] = []
        let last = DayKey.today(in: .berlin).adding(days: -end)
        var d = DayKey.today(in: .berlin).adding(days: -400)
        while d <= last {
            if d.weekday != 1 && d.weekday != 7 { out.append(Bar(day: d, close: 100)) }
            d = d.adding(days: 1)
        }
        return out
    }

    func answer(_ price: Double?, minutesAgo: Double = 1, name: String? = nil, barsEnd: Int = 0) -> ScriptedProvider.Answer {
        .init(price: price, time: now.addingTimeInterval(-minutesAgo * 60), name: name, bars: bars(endingDaysAgo: barsEnd))
    }

    struct Run {
        var engine: MarketEngine
        var depot: DepotFile
        var position: Position
        var quote: Quote? { get async { await engine.quote(position.listing.key) } }
        var history: PriceHistory? { get async { await engine.history(position.listing.key) } }
        var snapshot: EngineSnapshot { get async { await engine.snapshot(depot: depot) } }
    }

    func make(_ providers: [ScriptedProvider], name: String = "Alico", isin: String? = "US0162301040", ticker: String = "AOE",
              symbols: [String: String] = [:]) -> Run {
        let engine = MarketEngine(cacheDir: nil, router: DataRouter(registry: ProviderRegistry(providers)))
        let p = Position(name: name, isin: isin, listing: Listing(exchangeID: "XETR", ticker: ticker, symbols: symbols))
        return Run(engine: engine, depot: DepotFile(positions: [p]), position: p)
    }

    func refresh(_ r: Run) async {
        _ = await r.engine.refresh(depot: r.depot, keys: [:], force: true)
    }

    // MARK: Newest price wins

    func testOutdatedQuoteFallsBackToNextSource() async {
        let yahoo = ScriptedProvider(.yahoo, ["AOE.DE": answer(90, minutesAgo: 10 * 1440, name: "Alico")])
        let onvista = ScriptedProvider(.onvista, ["AOE": answer(101, name: "Alico")])
        let r = make([yahoo, onvista])
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.price, 101)
        XCTAssertEqual(q?.source, .onvista)
    }

    func testNewestOfOutdatedAnswersIsUsed() async {
        let yahoo = ScriptedProvider(.yahoo, ["AOE.DE": answer(90, minutesAgo: 15 * 1440, name: "Alico")])
        let onvista = ScriptedProvider(.onvista, ["AOE": answer(99, minutesAgo: 8 * 1440)])
        let r = make([yahoo, onvista])
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.price, 99, "the latest price any source has")
        let status = await r.snapshot.status[r.position.listing.key]
        XCTAssertTrue(status?.attempts.contains { $0.outdated } ?? false)
    }

    func testCurrentAnswerStopsTheSearch() async {
        let yahoo = ScriptedProvider(.yahoo, ["AOE.DE": answer(100, name: "Alico")])
        let onvista = ScriptedProvider(.onvista, ["AOE": answer(101)])
        let r = make([yahoo, onvista])
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.source, .yahoo)
        XCTAssertTrue(onvista.asked.isEmpty)
    }

    func testOlderAnswerNeverReplacesNewerCachedQuote() async {
        let yahoo = ScriptedProvider(.yahoo, ["AOE.DE": answer(100, minutesAgo: 1, name: "Alico")])
        let onvista = ScriptedProvider(.onvista, [:])
        let r = make([yahoo, onvista])
        await refresh(r)
        // Later every source only has an old price.
        yahoo.answers["AOE.DE"] = answer(80, minutesAgo: 9 * 1440, name: "Alico")
        await r.engine.forgetAttemptTimes()
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.price, 100)
    }

    func testOutdatedHistoryFallsBackToNextSource() async {
        // Yahoo stops 20 days ago (the case "Verlauf endet 16.10." with "Yahoo Finance: ok").
        let yahoo = ScriptedProvider(.yahoo, ["AOE.DE": answer(100, name: "Alico", barsEnd: 20)])
        let onvista = ScriptedProvider(.onvista, ["AOE": answer(100, barsEnd: 0)])
        let r = make([yahoo, onvista])
        await refresh(r)
        let h = await r.history
        XCTAssertEqual(h?.lastDay, bars(endingDaysAgo: 0).last?.day)
        XCTAssertEqual(h?.source, .onvista)
    }

    func testOnlyOutdatedHistoryIsStillUsed() async {
        let yahoo = ScriptedProvider(.yahoo, ["AOE.DE": answer(100, name: "Alico", barsEnd: 30)])
        let onvista = ScriptedProvider(.onvista, ["AOE": answer(100, barsEnd: 20)])
        let r = make([yahoo, onvista])
        await refresh(r)
        let h = await r.history
        XCTAssertEqual(h?.lastDay, bars(endingDaysAgo: 20).last?.day, "the newest history any source has")
    }

    // MARK: Wrong or empty symbols

    func testEmptySymbolIsRepairedThroughISIN() async {
        // "AOE" is Alico's German code; at the venue the ticker is another one.
        let yahoo = ScriptedProvider(.yahoo, ["ALCO.DE": answer(100, name: "Alico, Inc.")], isinSymbol: "ALCO.DE")
        let r = make([yahoo])
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.source, .yahoo)
        let c = await r.snapshot.corrections.first
        XCTAssertEqual(c?.ticker, "ALCO")
        XCTAssertEqual(c?.symbols["yahoo"], "ALCO.DE")
        XCTAssertNil(c?.wrongCompany, "nothing wrong was shown, only nothing at all")
    }

    func testWrongCompanyIsRejectedAndRepaired() async {
        let yahoo = ScriptedProvider(.yahoo, [
            "FCA-UN.DE": answer(4.15, name: "Firm Capital Apartment Real Estate Investment Trust"),
            "MTA.DE": answer(100, name: "Metalla Royalty & Streaming Ltd."),
        ], isinSymbol: "MTA.DE")
        let r = make([yahoo], name: "Metalla Royalty & Streaming", isin: "CA59124U6051", ticker: "FCA.UN", symbols: ["yahoo": "FCA-UN.DE"])
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.price, 100)
        let snap = await r.snapshot
        let c = snap.corrections.first
        XCTAssertEqual(c?.ticker, "MTA")
        XCTAssertEqual(c?.symbols["yahoo"], "MTA.DE")
        XCTAssertEqual(c?.wrongCompany, "Firm Capital Apartment Real Estate Investment Trust")
        let h = await r.history
        XCTAssertNil(h, "history that may come from the other company is dropped")

        // The app writes the correction into the depot.
        let newKey = c!.newKey(exchangeID: "XETR")
        await r.engine.applied(c!, newKey: newKey)
        let after = await r.snapshot
        XCTAssertTrue(after.corrections.isEmpty)
        XCTAssertEqual(after.notices[newKey]?.kind, .corrected)
        XCTAssertTrue(after.notices[newKey]?.detail.contains("Firm Capital") ?? false)
    }

    func testWrongCompanyWithoutRepairIsNeverUsed() async {
        let yahoo = ScriptedProvider(.yahoo, ["FCA.DE": answer(4.15, name: "Firm Capital Apartment Real Estate Investment Trust")])
        let onvista = ScriptedProvider(.onvista, ["FCA": answer(100)])
        let r = make([yahoo, onvista], name: "Metalla Royalty & Streaming", isin: nil, ticker: "FCA")
        await refresh(r)
        let q = await r.quote
        XCTAssertEqual(q?.price, 100)
        XCTAssertEqual(q?.source, .onvista)
        let snap = await r.snapshot
        XCTAssertEqual(snap.notices[r.position.listing.key]?.kind, .check)
        XCTAssertNotEqual(snap.status[r.position.listing.key]?.historySource, .yahoo)
    }

    func testOtherNameWithMatchingISINWaitsForConfirmation() async {
        // Either the names merely differ or the ISIN belongs to another company: the user decides.
        let yahoo = ScriptedProvider(.yahoo, ["GOOGL.DE": answer(100, name: "Alphabet Inc.")], isinSymbol: "GOOGL.DE")
        let r = make([yahoo], name: "Google", isin: "US02079K3059", ticker: "GOOGL")
        await refresh(r)
        let q = await r.quote
        XCTAssertNil(q, "not used before the user confirms")
        let snap = await r.snapshot
        let n = snap.notices[r.position.listing.key]
        XCTAssertEqual(n?.kind, .confirm)
        XCTAssertEqual(n?.symbol, "GOOGL.DE")
        XCTAssertEqual(n?.reportedName, "Alphabet Inc.")

        // Confirmed: stored in the depot, then used.
        var depot = r.depot
        depot.positions[0].listing.confirmedSymbols = ["yahoo": "GOOGL.DE"]
        await r.engine.confirmedCompany(listingKey: r.position.listing.key)
        _ = await r.engine.refresh(depot: depot, keys: [:], force: true)
        let q2 = await r.engine.quote(r.position.listing.key)
        XCTAssertEqual(q2?.price, 100)
        let after = await r.engine.snapshot(depot: depot)
        XCTAssertNil(after.notices[r.position.listing.key])
    }

    func testSuspendedCompanyGetsNoDataOfAnother() async {
        // The customer's DGH International AB carried the Frankfurt ticker AXL1, which is Axfood.
        let yahoo = ScriptedProvider(.yahoo, ["AXL1.DE": answer(24.85, name: "Axfood AB (publ)")])
        let onvista = ScriptedProvider(.onvista, ["AXL1": answer(24.85, name: "Axfood")])
        let r = make([yahoo, onvista], name: "DGH INTERNATIONAL AB", isin: nil, ticker: "AXL1")
        await refresh(r)
        let q = await r.quote
        let h = await r.history
        XCTAssertNil(q)
        XCTAssertNil(h)
        let snap = await r.snapshot
        XCTAssertEqual(snap.notices[r.position.listing.key]?.kind, .check)
        XCTAssertFalse(snap.metrics[r.position.id]?.hasData ?? false, "no value in the depot total")
    }

    func testMatchingTickerNeedsNoCorrection() async {
        let yahoo = ScriptedProvider(.yahoo, ["ERIC-B.DE": answer(100, name: "Telefonaktiebolaget LM Ericsson (publ)")])
        let r = make([yahoo], name: "Ericsson B", isin: "SE0000108656", ticker: "ERIC B", symbols: ["yahoo": "ERIC-B.DE"])
        await refresh(r)
        let snap = await r.snapshot
        XCTAssertTrue(snap.corrections.isEmpty)
    }
}

final class CompanyNameTests: XCTestCase {
    func testSameCompany() {
        XCTAssertEqual(Lenient.sameCompany("IMMUCELL CORP. DL-,10", "ImmuCell Corporation"), true)
        XCTAssertEqual(Lenient.sameCompany("Alico", "Alico, Inc."), true)
        XCTAssertEqual(Lenient.sameCompany("Metalla Royalty & Streaming", "Metalla Royalty & Streaming Ltd."), true)
        XCTAssertEqual(Lenient.sameCompany("Toyota", "Toyota Motor Corporation"), true)
        XCTAssertEqual(Lenient.sameCompany("Nestlé", "Nestle S.A."), true)
        XCTAssertEqual(Lenient.sameCompany("KAZATOMPROM GDR", "National Atomic Company Kazatomprom Joint Stock Company"), true)
        XCTAssertEqual(Lenient.sameCompany("Ericsson B", "Telefonaktiebolaget LM Ericsson (publ)"), true)
        XCTAssertEqual(Lenient.sameCompany("MUENCH.RUECKVERS.VNA O.N.", "Münchener Rückversicherungs-Gesellschaft AG"), true)
        XCTAssertEqual(Lenient.sameCompany("GR.AERO.D.CEN.NOR.B", "Grupo Aeroportuario del Centro Norte, S.A.B. de C.V."), true)
        XCTAssertEqual(Lenient.sameCompany("BOERSE STUTTG. EUWAX", "Börse Stuttgart"), true)
        XCTAssertEqual(Lenient.sameCompany("PAMPA ENERGIA SA GDR", "Pampa Energía S.A."), true)
    }

    func testOtherCompany() {
        XCTAssertEqual(Lenient.sameCompany("Metalla Royalty & Streaming", "Firm Capital Apartment Real Estate Investment Trust"), false)
        XCTAssertEqual(Lenient.sameCompany("Cameco", "Camden Property Trust"), false)
        XCTAssertEqual(Lenient.sameCompany("DGH INTERNATIONAL AB", "Axfood AB (publ)"), false)
    }

    func testUndecidable() {
        // Only generic words: nothing can be said, so nothing is rejected.
        XCTAssertNil(Lenient.sameCompany("Uranium ETF", "Global X Uranium ETF"))
        XCTAssertNil(Lenient.sameCompany("3M", "3M Company"))
    }
}

final class CurrentnessTests: XCTestCase {
    let nasdaq = ExchangeCatalog()["XNAS"]!

    func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .utc
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testAfterTheCloseTheClosingPriceIsCurrent() {
        // Tuesday 27.10.2026, 21:15 in Berlin, Nasdaq closed at 16:00 New York (20:00 UTC).
        let now = utc(2026, 10, 27, 20, 15)
        let due = Currentness.quoteDue(nasdaq, interval: 900, now: now)
        XCTAssertLessThanOrEqual(due, utc(2026, 10, 27, 20, 0))
        XCTAssertGreaterThan(due, utc(2026, 10, 27, 19, 50))
        XCTAssertFalse(utc(2026, 10, 20, 20, 0) >= due, "a price from a week ago is not current")
    }

    func testWhileTradingAnHourOldPriceIsNotCurrent() {
        let now = utc(2026, 10, 27, 17, 0)
        let due = Currentness.quoteDue(nasdaq, interval: 900, now: now)
        XCTAssertEqual(due, now.addingTimeInterval(-45 * 60))
    }

    func testJustOpenedYesterdaysCloseIsCurrent() {
        let now = utc(2026, 10, 27, 13, 40)
        let due = Currentness.quoteDue(nasdaq, interval: 900, now: now)
        XCTAssertLessThanOrEqual(due, utc(2026, 10, 26, 20, 0))
    }

    func testHistoryGetsThreeHoursAfterTheClose() {
        XCTAssertEqual(Currentness.historyDue(nasdaq, now: utc(2026, 10, 27, 21, 0)), DayKey(iso: "2026-10-26"))
        XCTAssertEqual(Currentness.historyDue(nasdaq, now: utc(2026, 10, 27, 23, 30)), DayKey(iso: "2026-10-27"))
    }

    func testVenueTicker() {
        let c = ExchangeCatalog()
        XCTAssertEqual(YahooProvider.venueTicker("MTA.V", exchange: c["XTSX"]!), "MTA")
        XCTAssertEqual(YahooProvider.venueTicker("ALCO", exchange: c["XNAS"]!), "ALCO")
        XCTAssertNil(YahooProvider.venueTicker("CA59124U6051.SG", exchange: c["XSTU"]!))
    }
}
