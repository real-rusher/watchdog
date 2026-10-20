import XCTest
@testable import WatchdogCore

func fixture(_ name: String) throws -> Data {
    let base = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/import")
    return try Data(contentsOf: base.appendingPathComponent(name))
}

final class ImportTests: XCTestCase {
    let catalog = ExchangeCatalog()

    func drafts(_ file: String) throws -> (CSVImport.Table, [CSVImport.Field], [CSVImport.Draft]) {
        let sheets = try ImportFile.sheets(data: try fixture(file), filename: file)
        let t = CSVImport.bestTable(sheets)
        let map = CSVImport.guessMapping(t.headers, rows: t.rows)
        return (t, map, CSVImport.drafts(t, mapping: map, catalog: catalog))
    }

    // MARK: Plain text

    func testGermanCSV() {
        let csv = """
        Bezeichnung;ISIN;Stück;Kaufkurs;Kaufdatum;Börse;Depot;Thema
        Cameco Corp.;CA13321L1085;120;14,50;15.03.2021;Tradegate;Comdirect;Uran
        Toyota;JP3633400001;1.000;11,50;17.05.2019;Tokio;Sparkasse;
        Nur beobachten;US0378331005;;;;Nasdaq;;
        """
        let t = CSVImport.parse(csv)
        let map = CSVImport.guessMapping(t.headers, rows: t.rows)
        XCTAssertEqual(map, [.name, .isin, .quantity, .pricePerUnit, .day, .exchange, .bank, .theme])
        let d = CSVImport.drafts(t, mapping: map, catalog: catalog)
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d[0].quantity, 120)
        XCTAssertEqual(d[0].totalCost!, 1740, accuracy: 1e-9)
        XCTAssertEqual(d[0].exchangeID, "TGAT")
        XCTAssertEqual(d[1].quantity, 1000)
        XCTAssertEqual(d[1].exchangeID, "XTKS")
        XCTAssertEqual(d[1].lots.first?.day?.iso, "2019-05-17")
        XCTAssertNil(d[2].quantity)
        XCTAssertTrue(d.allSatisfy(\.include))
    }

    func testComdirectTransactions() throws {
        let (t, map, d) = try drafts("comdirect_umsaetze.csv")
        XCTAssertEqual(t.headers.first, "Buchungstag", "meta line skipped")
        XCTAssertEqual(map[t.headers.firstIndex(of: "Geschäftstag")!], .day, "trade date preferred over booking date")
        XCTAssertEqual(map[t.headers.firstIndex(of: "Stück / Nom.")!], .quantity)
        XCTAssertEqual(map[t.headers.firstIndex(of: "Umsatz in EUR")!], .totalCost)
        XCTAssertEqual(map[t.headers.firstIndex(of: "Ausführungskurs")!], .pricePerUnit)
        let names = d.map(\.name)
        XCTAssertEqual(names, ["UBS-ETF-MSCI WLD.S.R.DLAD", "UBS-ETF-MSCI E.MA.S.R.ADL", "CAMECO CORP.", "Müller Hdl. AG"])
        // Dot as decimal in the quantity column next to comma prices: 12.145 shares, not 12145.
        XCTAssertEqual(d[0].quantity!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(d[1].quantity!, 12.145, accuracy: 1e-9)
        // Cameco: 120 + 30 bought, 50 sold (oldest first) = 100 left: 70 from 2021, 30 from 2024.
        let cameco = d[2]
        XCTAssertEqual(cameco.wkn, "882017")
        XCTAssertEqual(cameco.quantity!, 100, accuracy: 1e-9)
        XCTAssertEqual(cameco.lots.count, 2)
        XCTAssertEqual(cameco.lots[0].quantity, 70, accuracy: 1e-9)
        XCTAssertEqual(cameco.lots[0].cost!, 1740 * 70 / 120, accuracy: 1e-6)
        XCTAssertEqual(cameco.lots[0].day?.iso, "2021-03-12")
        XCTAssertEqual(cameco.lots[1].cost!, 1236, accuracy: 1e-6)
        XCTAssertTrue(cameco.notes.contains { $0.contains("3 Zeilen") })
        XCTAssertEqual(d[3].totalCost!, 10205, accuracy: 1e-6)
    }

    func testExcelUnicodeText() throws {
        let (_, _, d) = try drafts("excel_unicode.txt")
        XCTAssertEqual(d.map(\.name), ["SAP SE", "Nestlé S.A."])
        XCTAssertEqual(d[0].totalCost, 2380)
        XCTAssertEqual(d[1].lots.first?.day?.iso, "2022-02-01")
    }

    func testMacRoman() throws {
        let (_, map, d) = try drafts("mac_roman.csv")
        XCTAssertEqual(map, [.name, .isin, .quantity, .pricePerUnit, .day, .theme])
        XCTAssertEqual(d.map(\.name), ["Nestlé", "Österreichische Post"])
        XCTAssertEqual(d[1].theme, "Österreich")
        XCTAssertEqual(d[1].totalCost!, 1260, accuracy: 1e-9)
    }

    func testEnglishBroker() throws {
        let (_, map, d) = try drafts("english_broker.csv")
        XCTAssertEqual(map, [.ticker, .name, .quantity, .totalCost, .day, .currency])
        XCTAssertEqual(d[0].ticker, "NEM")
        XCTAssertEqual(d[0].totalCost!, 1712.40, accuracy: 1e-9)
        XCTAssertEqual(d[0].costCurrency, "USD")
        XCTAssertEqual(d[0].lots.first?.day?.iso, "2024-04-03", "US date order detected from 03/15/2021")
        XCTAssertEqual(d[1].quantity, 1200)
        XCTAssertTrue(d[0].notes.contains { $0.contains("USD") })
    }

    func testISINList() throws {
        let (t, map, d) = try drafts("isin_liste.txt")
        XCTAssertTrue(t.syntheticHeaders)
        XCTAssertEqual(map, [.isin])
        XCTAssertEqual(d.map(\.isin), ["CA13321L1085", "JP3633400001", "NO0010096985"])
        XCTAssertTrue(d.allSatisfy { $0.quantity == nil })
    }

    func testNameList() throws {
        let (t, map, d) = try drafts("namen_liste.txt")
        XCTAssertTrue(t.syntheticHeaders)
        XCTAssertEqual(map, [.name])
        XCTAssertEqual(d.map(\.name), ["Cameco", "Paladin Energy", "NexGen Energy"])
    }

    func testPastedFromNumbersWithCurrencySigns() {
        let tsv = "Aktie\tStück\tKaufpreis\tGekauft am\nCameco\t120 Stk.\t1.740,00 €\t15. März 2021\nPaladin\t400\t1.620 €\t1.6.2023\n"
        let t = CSVImport.parse(tsv)
        let map = CSVImport.guessMapping(t.headers, rows: t.rows)
        XCTAssertEqual(map, [.name, .quantity, .pricePerUnit, .day])
        let d = CSVImport.drafts(t, mapping: map, catalog: catalog)
        XCTAssertEqual(d[0].quantity, 120)
        XCTAssertEqual(d[0].lots[0].day?.iso, "2021-03-15")
        XCTAssertEqual(d[1].lots[0].day?.iso, "2023-06-01")
    }

    func testCurrentPriceColumnIsNotPurchasePrice() {
        let csv = "Name;ISIN;Stück;Akt. Kurs;Kaufkurs in EUR;Wert in EUR\nCameco;CA13321L1085;10;72,54;14,50;725,40\n"
        let t = CSVImport.parse(csv)
        let map = CSVImport.guessMapping(t.headers, rows: t.rows)
        XCTAssertEqual(map, [.name, .isin, .quantity, .ignore, .pricePerUnit, .ignore])
        XCTAssertEqual(CSVImport.drafts(t, mapping: map, catalog: catalog)[0].totalCost, 145)
    }

    func testWithoutPurchasePrice() {
        let t = CSVImport.parse("Name;ISIN;Stück\nCameco;CA13321L1085;10\n")
        let d = CSVImport.drafts(t, mapping: CSVImport.guessMapping(t.headers), catalog: catalog)
        XCTAssertNil(d[0].totalCost)
        XCTAssertTrue(d[0].issues.contains { $0.contains("Kaufpreis fehlt") })
    }

    func testSoldOutIsExcluded() {
        let t = CSVImport.parse("Name;ISIN;Stück;Kaufkurs;Art\nCameco;CA13321L1085;10;14,50;Kauf\nCameco;CA13321L1085;10;40,00;Verkauf\nCameco;CA13321L1085;;;Dividende\n")
        let d = CSVImport.drafts(t, mapping: CSVImport.guessMapping(t.headers), catalog: catalog)
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].soldOut)
        XCTAssertFalse(d[0].include)
    }

    func testPenceAreConverted() {
        let t = CSVImport.parse("Name;ISIN;Stück;Kaufkurs;Währung\nYellow Cake;JE00BF50RG45;100;512,00;GBX\n")
        let d = CSVImport.drafts(t, mapping: CSVImport.guessMapping(t.headers), catalog: catalog)
        XCTAssertEqual(d[0].costCurrency, "GBP")
        XCTAssertEqual(d[0].totalCost!, 512, accuracy: 1e-9)
    }

    // MARK: Spreadsheets

    func checkWorkbook(_ file: String) throws {
        let (t, map, d) = try drafts(file)
        XCTAssertEqual(t.sheetName, "Depot", "\(file): the sheet with the table is chosen")
        XCTAssertEqual(map.prefix(6), [.name, .isin, .wkn, .quantity, .pricePerUnit, .day], file)
        XCTAssertEqual(d.map(\.name), ["Cameco Corp.", "Toyota Motor Corp.", "Equinor ASA", "Kazatomprom GDR"], file)
        let cameco = d[0]
        XCTAssertEqual(cameco.quantity!, 150, accuracy: 1e-9, file)
        XCTAssertEqual(cameco.totalCost!, 120 * 14.5 + 30 * 41.2, accuracy: 1e-6, file)
        XCTAssertEqual(cameco.lots.map { $0.day?.iso ?? "" }, ["2021-03-15", "2024-02-01"], file)
        XCTAssertEqual(cameco.exchangeID, "TGAT", file)
        XCTAssertEqual(cameco.bank, "Comdirect", file)
        XCTAssertEqual(cameco.note, "Kernposition", file)
        XCTAssertEqual(d[1].exchangeID, "XTKS", file)
        XCTAssertEqual(d[2].quantity!, 12.145, accuracy: 1e-9, file)
        XCTAssertEqual(d[2].theme, "Öl & Gas", file)
        XCTAssertEqual(d[2].exchangeID, "XOSL", file)
        XCTAssertNil(d[3].quantity, file)
    }

    func testXLSXFromOpenpyxl() throws { try checkWorkbook("depot_openpyxl.xlsx") }
    func testXLSXFromLibreOffice() throws { try checkWorkbook("depot_libreoffice.xlsx") }
    func testODS() throws { try checkWorkbook("depot.ods") }

    func testOldExcelAndNumbersExplainThemselves() throws {
        XCTAssertThrowsError(try ImportFile.sheets(data: try fixture("depot_alt.xls"), filename: "depot_alt.xls")) { e in
            XCTAssertTrue((e as? LocalizedError)?.errorDescription?.contains(".xlsx") ?? false)
        }
        XCTAssertThrowsError(try ImportFile.sheets(data: Data("x".utf8), filename: "Depot.numbers")) { e in
            XCTAssertTrue((e as? LocalizedError)?.errorDescription?.contains("Numbers") ?? false)
        }
    }

    func testInflateMatchesStoredData() throws {
        let zip = try ZipArchive(data: try fixture("depot_openpyxl.xlsx"))
        let xml = try XCTUnwrap(try zip.data("xl/workbook.xml"))
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("Depot"))
    }

    func testDates() {
        XCTAssertEqual(Lenient.day("44270")?.iso, "2021-03-15")
        XCTAssertEqual(Lenient.day("2021-03-15T10:22:00Z")?.iso, "2021-03-15")
        XCTAssertEqual(Lenient.day("15.03.21")?.iso, "2021-03-15")
        XCTAssertEqual(Lenient.day("15. März 2021")?.iso, "2021-03-15")
        XCTAssertEqual(Lenient.day("04/03/2024", monthFirst: true)?.iso, "2024-04-03")
        XCTAssertEqual(Lenient.day("04/03/2024", monthFirst: false)?.iso, "2024-03-04")
    }
}

final class ResolverTests: XCTestCase {
    let catalog = ExchangeCatalog()

    func cand(_ p: ProviderID, _ name: String, isin: String?, ex: ExchangeID, ticker: String) -> SearchCandidate {
        SearchCandidate(provider: p, name: name, isin: isin, ticker: ticker, symbol: ticker, exchangeID: ex, exchangeLabel: ex)
    }

    func draft(name: String, isin: String? = nil, ticker: String? = nil, exchange: ExchangeID? = nil) -> CSVImport.Draft {
        CSVImport.Draft(rows: [1], name: name, isin: isin, wkn: nil, ticker: ticker, exchangeText: nil, exchangeID: exchange, lots: [],
                        bank: nil, theme: nil, note: "", issues: [], notes: [], soldOut: false, include: true)
    }

    func testExactVenue() {
        let groups = ListingOption.build([
            cand(.onvista, "Cameco", isin: "CA13321L1085", ex: "TGAT", ticker: "CJ6"),
            cand(.yahoo, "Cameco Corp", isin: nil, ex: "XNYS", ticker: "CCJ"),
        ], query: "CA13321L1085", catalog: catalog)
        let d = draft(name: "Cameco", isin: "CA13321L1085")
        let g = ImportResolver.instrument(for: d, in: groups, query: "CA13321L1085")!
        let c = ImportResolver.choose(d, group: g, target: "TGAT", catalog: catalog)!
        XCTAssertEqual(c.option.exchangeID, "TGAT")
        XCTAssertNil(c.note)
        XCTAssertEqual(c.alternatives.count, 2)
    }

    func testFallsBackToGermanVenue() {
        let groups = ListingOption.build([
            cand(.ft, "Paladin Energy", isin: "AU000000PDN8", ex: "XASX", ticker: "PDN"),
            cand(.onvista, "Paladin Energy", isin: "AU000000PDN8", ex: "XFRA", ticker: "PD8"),
        ], query: "AU000000PDN8", catalog: catalog)
        let d = draft(name: "Paladin", isin: "AU000000PDN8")
        let c = ImportResolver.choose(d, group: ImportResolver.instrument(for: d, in: groups, query: "AU000000PDN8")!, target: "TGAT", catalog: catalog)!
        XCTAssertEqual(c.option.exchangeID, "XFRA")
        XCTAssertTrue(c.note?.contains("Tradegate") ?? false)
    }

    func testNameSearchDoesNotTakeAnotherCompany() {
        let groups = ListingOption.build([
            cand(.yahoo, "Enel SpA", isin: "IT0003128367", ex: "XMIL", ticker: "ENEL"),
        ], query: "Eni", catalog: catalog)
        XCTAssertNil(ImportResolver.instrument(for: draft(name: "Eni"), in: groups, query: "Eni"))
        let ok = ListingOption.build([cand(.yahoo, "Eni S.p.A.", isin: "IT0003132476", ex: "XMIL", ticker: "ENI")], query: "Eni", catalog: catalog)
        XCTAssertNotNil(ImportResolver.instrument(for: draft(name: "ENI SpA"), in: ok, query: "ENI SpA"))
    }

    func testISINMismatchIsRejected() {
        let groups = ListingOption.build([cand(.yahoo, "Other", isin: "US0000000001", ex: "XNYS", ticker: "OTH")], query: "Cameco", catalog: catalog)
        XCTAssertNil(ImportResolver.instrument(for: draft(name: "Cameco", isin: "CA13321L1085"), in: groups, query: "Cameco"))
    }
}

final class CostTests: XCTestCase {
    func testPurchaseWithoutPriceIsNotProfit() {
        let ex = ExchangeCatalog()["XETR"]!
        var bars: [Bar] = []
        var d = DayKey(iso: "2025-01-02")!
        while bars.count < 260 {
            if d.weekday != 1 && d.weekday != 7 { bars.append(Bar(day: d, close: 100)) }
            d = d.adding(days: 1)
        }
        let p = Position(name: "T", listing: Listing(exchangeID: "XETR", ticker: "T"), lots: [Lot(day: bars[0].day, quantity: 10, totalCostEUR: 0)])
        let m = Evaluator.evaluate(position: p, exchange: ex, history: bars, quote: nil, currency: "EUR", rules: RuleSet(), fx: { _, _ in 1 })
        XCTAssertEqual(m.valueEUR, 1000)
        XCTAssertNil(m.costEUR)
        XCTAssertNil(m.sincePurchaseEUR)
        XCTAssertNil(m.sincePurchasePercent)
        XCTAssertNil(p.averagePriceEUR)
    }
}

final class DemoDataTests: XCTestCase {
    func testStressDepotShapes() async {
        let (depot, provider) = DemoData.stress()
        let engine = MarketEngine(cacheDir: nil, router: DataRouter(registry: ProviderRegistry([provider])))
        _ = await engine.refresh(depot: depot, keys: [:], force: true)
        let snap = await engine.snapshot(depot: depot)
        func m(_ name: String) -> PositionMetrics? {
            depot.positions.first { $0.name.hasPrefix(name) }.flatMap { snap.metrics[$0.id] }
        }
        XCTAssertEqual(m("Frisch gefallen")?.ampel.state, .red)
        XCTAssertEqual(m("Frisch gefallen")?.ampel.isFresh, true)
        XCTAssertEqual(m("Frisch gestiegen")?.ampel.state, .green)
        XCTAssertEqual(m("Frisch gestiegen")?.ampel.isFresh, true)
        XCTAssertEqual(m("Knapp an der Linie")?.ampel.state, .yellow)
        XCTAssertEqual(m("Absturz")?.quoteSuspect, true)
        XCTAssertNil(m("Ohne Kaufpreis")?.sincePurchasePercent)
        XCTAssertNotNil(m("Ohne Kaufpreis")?.valueEUR)
        XCTAssertGreaterThan(m("Riesenposition")?.valueEUR ?? 0, 10_000_000)
        XCTAssertFalse(m("Keine Daten")?.hasData ?? false)
    }
}

final class ResolverCurrencyTests: XCTestCase {
    func testUSDPurchasePrefersHomeVenue() {
        let catalog = ExchangeCatalog()
        let groups = ListingOption.build([
            SearchCandidate(provider: .twelvedata, name: "Cameco Corp", ticker: "CCJ", symbol: "CCJ|XHAN", exchangeID: "XHAN", exchangeLabel: "Hannover"),
            SearchCandidate(provider: .twelvedata, name: "Cameco Corp", ticker: "CCJ", symbol: "CCJ|XNYS", exchangeID: "XNYS", exchangeLabel: "NYSE"),
            SearchCandidate(provider: .onvista, name: "Cameco Corp", ticker: "CJ6", symbol: "STOCK|1|2", exchangeID: "XFRA", exchangeLabel: "Frankfurt"),
        ], query: "CCJ", catalog: catalog)
        var d = CSVImport.Draft(rows: [1], name: "CAMECO CORP", isin: nil, wkn: nil, ticker: "CCJ", exchangeText: nil, exchangeID: nil,
                                lots: [CSVImport.DraftLot(day: nil, quantity: 10, cost: 100, currency: "USD", row: 1)],
                                bank: nil, theme: nil, note: "", issues: [], notes: [], soldOut: false, include: true)
        let g = ImportResolver.instrument(for: d, in: groups, query: "CCJ")!
        XCTAssertEqual(ImportResolver.choose(d, group: g, target: "TGAT", catalog: catalog)?.option.exchangeID, "XNYS")
        d.lots[0].currency = "EUR"
        XCTAssertEqual(ImportResolver.choose(d, group: g, target: "TGAT", catalog: catalog)?.option.exchangeID, "XFRA")
    }
}

final class TickerMergeTests: XCTestCase {
    func testSplitNamesAreMergedForTicker() {
        let catalog = ExchangeCatalog()
        let groups = ListingOption.build([
            SearchCandidate(provider: .twelvedata, name: "CAMECO CORP. REG. SHARES", ticker: "CCJ", symbol: "CCJ|XHAN", exchangeID: "XHAN", exchangeLabel: "Hannover"),
            SearchCandidate(provider: .yahoo, name: "Cameco Corporation", ticker: "CCJ", symbol: "CCJ", exchangeID: "XNYS", exchangeLabel: "NYSE"),
            SearchCandidate(provider: .yahoo, name: "Royal Gold", ticker: "RGLD", symbol: "RGLD", exchangeID: "XNAS", exchangeLabel: "Nasdaq"),
        ], query: "CCJ", catalog: catalog)
        let d = CSVImport.Draft(rows: [1], name: "CAMECO CORP", isin: nil, wkn: nil, ticker: "CCJ", exchangeText: nil, exchangeID: nil,
                                lots: [CSVImport.DraftLot(day: nil, quantity: 10, cost: 100, currency: "USD", row: 1)],
                                bank: nil, theme: nil, note: "", issues: [], notes: [], soldOut: false, include: true)
        let g = ImportResolver.instrument(for: d, in: groups, query: "CCJ")!
        XCTAssertEqual(Set(g.compactMap(\.exchangeID)), ["XHAN", "XNYS"])
        XCTAssertEqual(ImportResolver.choose(d, group: g, target: "TGAT", catalog: catalog)?.option.exchangeID, "XNYS")
    }

    func testTinyPricesKeepDigits() {
        XCTAssertTrue(Format.number(0.000614).hasPrefix("0,000614"))
        XCTAssertEqual(Format.number(12.5), "12,50")
    }
}
