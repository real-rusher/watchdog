import XCTest
@testable import WatchdogCore

final class IndicatorTests: XCTestCase {
    func testSMA() {
        let v: [Double] = [1, 2, 3, 4, 5]
        let s = Indicators.sma(v, 3)
        XCTAssertNil(s[0]); XCTAssertNil(s[1])
        XCTAssertEqual(s[2]!, 2, accuracy: 1e-9)
        XCTAssertEqual(s[4]!, 4, accuracy: 1e-9)
    }

    func testEMA() {
        let v: [Double] = [10, 10, 10, 20]
        let e = Indicators.ema(v, 3)
        XCTAssertEqual(e[2]!, 10, accuracy: 1e-9)
        XCTAssertEqual(e[3]!, 15, accuracy: 1e-9)
    }

    func testCrossings() {
        let a: [Double?] = [1, 2, 3, 2, 1, 1, 3]
        let b: [Double?] = [2, 2, 2, 2, 2, 2, 2]
        let c = Indicators.crossings(a, b)
        XCTAssertEqual(c.map(\.index), [2, 4, 6])
        XCTAssertEqual(c.map(\.direction), [.up, .down, .up])
    }
}

final class ParsingTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(Lenient.double("1.234,56"), 1234.56)
        XCTAssertEqual(Lenient.double("1,234.56"), 1234.56)
        XCTAssertEqual(Lenient.double("12,5"), 12.5)
        XCTAssertEqual(Lenient.double("-3,2 %"), -3.2)
        XCTAssertEqual(Lenient.double("1.234.567"), 1234567)
        XCTAssertEqual(Lenient.double("2.000,00 €"), 2000)
        XCTAssertNil(Lenient.double(""))
    }

    func testDays() {
        XCTAssertEqual(Lenient.day("15.03.2021")?.value, 20210315)
        XCTAssertEqual(Lenient.day("2021-03-15")?.value, 20210315)
        XCTAssertEqual(Lenient.day("15.03.21")?.value, 20210315)
    }

    func testISIN() {
        XCTAssertTrue(Lenient.isISIN("DE0007164600"))
        XCTAssertTrue(Lenient.isISIN("jp3633400001"))
        XCTAssertFalse(Lenient.isISIN("SAP"))
    }

    func testDayKeyMath() {
        let d = DayKey(iso: "2026-03-01")!
        XCTAssertEqual(d.adding(days: -1).iso, "2026-02-28")
        XCTAssertEqual(DayKey(iso: "2026-01-01")!.days(to: DayKey(iso: "2026-01-31")!), 30)
        XCTAssertEqual(DayKey(iso: "2026-10-17")!.weekday, 7) // Saturday
    }

    func testCurrencyNormalizer() {
        XCTAssertEqual(CurrencyNormalizer.normalize("GBp"), .init(code: "GBP", factor: 0.01))
        XCTAssertEqual(CurrencyNormalizer.normalize("UST").code, "USD")
        XCTAssertEqual(CurrencyNormalizer.normalize("jpy").code, "JPY")
    }
}

final class CatalogTests: XCTestCase {
    let cat = ExchangeCatalog()

    func testYahooMapping() {
        XCTAssertEqual(cat.matchYahoo(symbol: "7203.T", exchangeCode: "JPX")?.id, "XTKS")
        XCTAssertEqual(cat.matchYahoo(symbol: "SAP.DE", exchangeCode: "GER")?.id, "XETR")
        XCTAssertEqual(cat.matchYahoo(symbol: "AAPL", exchangeCode: "NMS")?.id, "XNAS")
        XCTAssertEqual(cat.matchYahoo(symbol: "TM", exchangeCode: "NYQ")?.id, "XNYS")
        XCTAssertEqual(cat.matchYahoo(symbol: "PALAF", exchangeCode: "PNK")?.id, "OOTC")
        XCTAssertEqual(cat.matchYahoo(symbol: "ERIC-B.ST", exchangeCode: "STO")?.id, "SSME")
        XCTAssertEqual(cat.matchYahoo(symbol: "SYH.V", exchangeCode: "VAN")?.id, "XTSX")
    }

    func testOtherMappings() {
        XCTAssertEqual(cat.match(.onvista, code: "_GAT")?.id, "TGAT")
        XCTAssertEqual(cat.match(.onvista, code: "_TRO")?.id, "GETX")
        XCTAssertEqual(cat.match(.onvista, code: "_LSX")?.id, "LSEX")
        XCTAssertEqual(cat.match(.ft, code: "TYO")?.id, "XTKS")
        XCTAssertEqual(cat.match(.ft, code: "CVE")?.id, "XTSX")
        XCTAssertEqual(cat.match(.twelvedata, code: "XJPX")?.id, "XTKS")
        XCTAssertEqual(cat.matchName("Tokio")?.id, "XTKS")
        XCTAssertEqual(cat.matchName("tradegate")?.id, "TGAT")
        XCTAssertEqual(cat.matchName("LS Exchange")?.id, "LSEX")
        XCTAssertEqual(cat.active.count, 19)
    }

    func testMarketHours() {
        let xetra = cat["XETR"]!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let wedNoon = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let wedNight = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 20))!
        let sat = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        XCTAssertTrue(xetra.isOpen(at: wedNoon))
        XCTAssertFalse(xetra.isOpen(at: wedNight))
        XCTAssertFalse(xetra.isOpen(at: sat))
        XCTAssertEqual(xetra.lastCompletedSession(at: wedNoon).iso, "2026-10-13")
        XCTAssertEqual(xetra.lastCompletedSession(at: wedNight).iso, "2026-10-14")
        XCTAssertEqual(xetra.lastCompletedSession(at: sat).iso, "2026-10-16")
    }
}

final class EvaluationTests: XCTestCase {
    /// 260 rising days, then a sharp drop below the 200-day line.
    func makeBars(drop: Bool) -> [Bar] {
        var bars: [Bar] = []
        var d = DayKey(iso: "2025-01-02")!
        var price = 100.0
        var i = 0
        while bars.count < 300 {
            if d.weekday != 1 && d.weekday != 7 {
                price += 0.2
                if drop && i > 296 { price = 100 }
                bars.append(Bar(day: d, close: price))
                i += 1
            }
            d = d.adding(days: 1)
        }
        return bars
    }

    func position(lots: [Lot] = [Lot(day: DayKey(iso: "2025-01-02")!, quantity: 10, totalCostEUR: 1000)]) -> Position {
        Position(name: "Test AG", listing: Listing(exchangeID: "XETR", ticker: "TST"), lots: lots)
    }

    func testGreenWhenAbove() {
        let ex = ExchangeCatalog()["XETR"]!
        let m = Evaluator.evaluate(position: position(), exchange: ex, history: makeBars(drop: false), quote: nil, currency: "EUR",
                                   rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m.ampel.state, .green)
        XCTAssertNotNil(m.lineValues[.sma(200)])
        XCTAssertNotNil(m.lineValues[.sma(38)])
        XCTAssertEqual(m.valueEUR!, 10 * makeBars(drop: false).last!.close, accuracy: 1e-6)
        XCTAssertTrue(m.sincePurchasePercent! > 0)
        XCTAssertNotNil(m.ytdPercent)
        XCTAssertNotNil(m.days30Percent)
    }

    func testRedAndCrossingEvent() {
        let ex = ExchangeCatalog()["XETR"]!
        let m = Evaluator.evaluate(position: position(), exchange: ex, history: makeBars(drop: true), quote: nil, currency: "EUR",
                                   rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m.ampel.state, .red)
        XCTAssertEqual(m.ampel.lastCrossing?.direction, .down)
        XCTAssertTrue(m.ampel.isFresh)
        XCTAssertTrue(m.hits.contains { $0.rule.id == RuleSet.crossDownID })
    }

    func testYellowBand() {
        let ex = ExchangeCatalog()["XETR"]!
        var bars = makeBars(drop: false)
        let sma = Indicators.sma(bars.map(\.close), 200).last!!
        bars[bars.count - 1].close = sma * 1.01
        let m = Evaluator.evaluate(position: position(), exchange: ex, history: bars, quote: nil, currency: "EUR", rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m.ampel.state, .yellow)
        bars[bars.count - 1].close = sma * 0.99
        let m2 = Evaluator.evaluate(position: position(), exchange: ex, history: bars, quote: nil, currency: "EUR", rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m2.ampel.state, .red, "below the line stays red in the default mode")
    }

    func testFXConversionKeepsCrossings() {
        let ex = ExchangeCatalog()["XTKS"]!
        let bars = makeBars(drop: true)
        // Rate changes every day; crossings must stay at the same index in EUR.
        let pts = Evaluator.chart(history: bars, quote: nil, exchange: ex, currency: "JPY", lines: [.sma(200)], from: bars.first!.day,
                                  fx: { _, d in 1.0 / (150 + Double(d.day)) })
        let local = Indicators.crossings(bars.map(\.close), Indicators.sma(bars.map(\.close), 200))
        let eur = Indicators.crossings(pts.map(\.priceEUR), pts.map { $0.lines[.sma(200)] })
        XCTAssertEqual(local.map(\.index), eur.map(\.index))
    }

    func testLiveQuoteFoldsIn() {
        let ex = ExchangeCatalog()["XETR"]!
        let bars = makeBars(drop: false)
        let next = bars.last!.day.adding(days: 3)
        let q = Quote(price: 50, time: next.date, previousClose: bars.last!.close, currency: "EUR", source: .yahoo)
        let m = Evaluator.evaluate(position: position(), exchange: ex, history: bars, quote: q, currency: "EUR", rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m.priceLocal, 50)
        XCTAssertTrue(m.isLive)
        XCTAssertEqual(m.ampel.state, .red)
        XCTAssertEqual(m.dayChangePercent!, (50 / bars.last!.close - 1) * 100, accuracy: 1e-9)
    }

    func testWatchOnlyHasNoValue() {
        let ex = ExchangeCatalog()["XETR"]!
        let m = Evaluator.evaluate(position: position(lots: []), exchange: ex, history: makeBars(drop: false), quote: nil, currency: "EUR",
                                   rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertNil(m.valueEUR)
        XCTAssertNotNil(m.priceEUR)
    }

    func testSignalStateSuppressesHistoryAndFiresNew() {
        let ex = ExchangeCatalog()["XETR"]!
        let p = position()
        var state = SignalState()
        let rules = RuleSet()
        let m1 = Evaluator.evaluate(position: p, exchange: ex, history: makeBars(drop: true), quote: nil, currency: "EUR", rules: rules, fx: { _, _ in 1 })
        let day1 = makeBars(drop: true).last!.day
        XCTAssertTrue(state.process(metrics: m1, position: p, exchange: ex, rules: rules, today: day1).isEmpty, "first evaluation never notifies")
        // Next day: recovery above the line is a new event.
        var bars = makeBars(drop: true)
        let d = bars.last!.day.adding(days: 1)
        bars.append(Bar(day: d, close: 200))
        let m2 = Evaluator.evaluate(position: p, exchange: ex, history: bars, quote: nil, currency: "EUR", rules: rules, fx: { _, _ in 1 })
        let ev = state.process(metrics: m2, position: p, exchange: ex, rules: rules, today: d)
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(ev.first?.ruleName, rules.rules.first { $0.id == RuleSet.crossUpID }?.name)
        XCTAssertFalse(ev.first!.body.contains("\u{2013}"), "no dashes in user facing texts")
        XCTAssertTrue(state.process(metrics: m2, position: p, exchange: ex, rules: rules, today: d).isEmpty, "no duplicates")
    }
}

final class ImportTests: XCTestCase {
    func testGermanCSV() {
        let csv = """
        Bezeichnung;ISIN;Stück;Kaufkurs;Kaufdatum;Börse;Depot;Thema
        Cameco Corp.;CA13321L1085;120;14,50;15.03.2021;Tradegate;Comdirect;Uran
        Toyota;JP3633400001;1.000;11,50;17.05.2019;Tokio;Sparkasse;
        Nur beobachten;US0378331005;;;;Nasdaq;;
        """
        let t = CSVImport.parse(csv)
        XCTAssertEqual(t.delimiter, ";")
        let map = CSVImport.guessMapping(t.headers)
        XCTAssertEqual(map, [.name, .isin, .quantity, .pricePerUnit, .day, .exchange, .bank, .theme])
        let d = CSVImport.drafts(t, mapping: map, catalog: ExchangeCatalog())
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d[0].quantity, 120)
        XCTAssertEqual(d[0].totalCostEUR!, 1740, accuracy: 1e-9)
        XCTAssertEqual(d[0].exchangeID, "TGAT")
        XCTAssertEqual(d[1].quantity, 1000)
        XCTAssertEqual(d[1].exchangeID, "XTKS")
        XCTAssertEqual(d[1].day?.iso, "2019-05-17")
        XCTAssertNil(d[2].quantity)
    }

    func testTabSeparatedFromExcel() {
        let tsv = "Name\tISIN\tAnzahl\tKaufwert\nSAP\tDE0007164600\t25\t2.380,00\n"
        let t = CSVImport.parse(tsv)
        XCTAssertEqual(t.delimiter, "\t")
        let d = CSVImport.drafts(t, mapping: CSVImport.guessMapping(t.headers), catalog: ExchangeCatalog())
        XCTAssertEqual(d.first?.totalCostEUR, 2380)
    }
}

final class FXTests: XCTestCase {
    func testECBParse() {
        let xml = """
        <Cube><Cube time='2026-10-16'><Cube currency='USD' rate='1.1253'/><Cube currency='JPY' rate='177.82'/></Cube>
        <Cube time='2026-10-15'><Cube currency='USD' rate='1.12'/></Cube></Cube>
        """
        let r = FXService.parseECB(xml, currencies: ["USD", "JPY"], from: DayKey(iso: "2026-01-01")!)
        XCTAssertEqual(r["USD"]?[DayKey(iso: "2026-10-16")!], 1.1253)
        XCTAssertEqual(r["JPY"]?.count, 1)
    }

    func testLookupUsesPreviousDay() {
        var t = FXTable()
        t.merge("USD", [DayKey(iso: "2026-10-16")!: 1.25])
        XCTAssertEqual(t.eurPerUnit("USD", DayKey(iso: "2026-10-18")!)!, 0.8, accuracy: 1e-9)
        XCTAssertEqual(t.eurPerUnit("EUR", DayKey(iso: "2026-10-18")!), 1)
        XCTAssertNil(t.eurPerUnit("CHF", DayKey(iso: "2026-10-18")!))
    }
}

final class FileTests: XCTestCase {
    func testDepotRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DepotStore(url: dir.appendingPathComponent("Watchdog.json"))
        let depot = DepotFile.example()
        try store.save(depot)
        try store.save(depot)
        let loaded = try store.load()
        XCTAssertEqual(loaded.positions.count, depot.positions.count)
        XCTAssertEqual(loaded.rules.rules.count, RuleSet.defaultRules.count)
        XCTAssertEqual(store.backups().count, 1)
    }

    func testTolerantDecoding() throws {
        let json = #"{"positions": [], "rules": {"ampel": {"line": {"kind": "sma", "length": 100}}}}"#
        let d = try DepotStore.decoder().decode(DepotFile.self, from: Data(json.utf8))
        XCTAssertEqual(d.rules.ampel.line, .sma(100))
        XCTAssertEqual(d.rules.ampel.yellowBandPercent, 2)
        XCTAssertEqual(d.rules.rules.count, RuleSet.defaultRules.count)
        XCTAssertEqual(d.sources.order.count, ProviderID.allCases.count)
    }
}
