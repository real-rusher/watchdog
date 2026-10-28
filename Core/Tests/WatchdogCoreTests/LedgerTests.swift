import XCTest
@testable import WatchdogCore

final class LedgerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func event(_ id: String, at t: Date) -> SignalEvent {
        SignalEvent(id: id, positionID: UUID(), positionName: "Cameco", exchangeName: "Tradegate", ruleName: "200-Tage-Linie nach unten",
                    severity: .alarm, day: DayKey(date: t), title: "Cameco · Tradegate", body: "200-Tage-Linie nach unten", createdAt: t)
    }

    func testMacIsOnDutyWhileItChecks() {
        var ledger = NotificationLedger()
        var mac = NotificationCoordinator(role: .mac)
        var phone = NotificationCoordinator(role: .iphone)
        let e = event("a", at: t0)
        let m = mac.cycle(ledger: &ledger, newEvents: [e], healthy: true, device: "Mac", now: t0)
        XCTAssertEqual(m.deliver.map(\.id), ["a"])
        let p = phone.cycle(ledger: &ledger, newEvents: [e], healthy: true, device: "iPhone", now: t0.addingTimeInterval(60))
        XCTAssertTrue(p.deliver.isEmpty, "already announced by the Mac")
        XCTAssertEqual(p.onDuty, .mac)
        XCTAssertTrue(phone.pending.isEmpty)
    }

    func testIPhoneTakesOverWhenMacStops() {
        var ledger = NotificationLedger()
        var mac = NotificationCoordinator(role: .mac)
        var phone = NotificationCoordinator(role: .iphone)
        _ = mac.cycle(ledger: &ledger, newEvents: [], healthy: true, device: "Mac", now: t0)
        // Ten minutes later the Mac still counts: the iPhone keeps its event back.
        let early = phone.cycle(ledger: &ledger, newEvents: [event("b", at: t0)], healthy: true, device: "iPhone", now: t0.addingTimeInterval(600))
        XCTAssertTrue(early.deliver.isEmpty)
        XCTAssertEqual(phone.pending.count, 1)
        // The Mac went to sleep: after 20 minutes the iPhone announces, including what it held back.
        let late = phone.cycle(ledger: &ledger, newEvents: [], healthy: true, device: "iPhone", now: t0.addingTimeInterval(25 * 60))
        XCTAssertEqual(late.onDuty, .iphone)
        XCTAssertEqual(late.deliver.map(\.id), ["b"])
        XCTAssertEqual(ledger.reportedBy["b"], .iphone)
        // Back awake, the Mac does not repeat it.
        let back = mac.cycle(ledger: &ledger, newEvents: [event("b", at: t0)], healthy: true, device: "Mac", now: t0.addingTimeInterval(40 * 60))
        XCTAssertTrue(back.deliver.isEmpty)
    }

    func testUnhealthyMacHandsOver() {
        var ledger = NotificationLedger()
        var mac = NotificationCoordinator(role: .mac)
        var phone = NotificationCoordinator(role: .iphone)
        _ = phone.cycle(ledger: &ledger, newEvents: [], healthy: true, device: "iPhone", now: t0)
        // The Mac runs but gets no data (no internet, sources down).
        let m = mac.cycle(ledger: &ledger, newEvents: [], healthy: false, device: "Mac", now: t0.addingTimeInterval(60))
        XCTAssertEqual(m.onDuty, .iphone)
        let p = phone.cycle(ledger: &ledger, newEvents: [event("c", at: t0)], healthy: true, device: "iPhone", now: t0.addingTimeInterval(120))
        XCTAssertEqual(p.deliver.map(\.id), ["c"])
    }

    func testWatchIsLast() {
        var ledger = NotificationLedger()
        var watch = NotificationCoordinator(role: .watch)
        ledger.heartbeat(.mac, healthy: true, device: "Mac", now: t0)
        ledger.heartbeat(.iphone, healthy: true, device: "iPhone", now: t0)
        XCTAssertTrue(watch.cycle(ledger: &ledger, newEvents: [event("d", at: t0)], healthy: true, device: "Watch", now: t0.addingTimeInterval(300)).deliver.isEmpty)
        // Mac asleep, iPhone still checking: still not the Watch.
        ledger.heartbeat(.iphone, healthy: true, device: "iPhone", now: t0.addingTimeInterval(30 * 60))
        XCTAssertEqual(watch.cycle(ledger: &ledger, newEvents: [], healthy: true, device: "Watch", now: t0.addingTimeInterval(31 * 60)).onDuty, .iphone)
        // Both silent.
        let w = watch.cycle(ledger: &ledger, newEvents: [], healthy: true, device: "Watch", now: t0.addingTimeInterval(55 * 60))
        XCTAssertEqual(w.onDuty, .watch)
        XCTAssertEqual(w.deliver.map(\.id), ["d"])
    }

    func testOldPendingEventsExpire() {
        var ledger = NotificationLedger()
        ledger.heartbeat(.mac, healthy: true, device: "Mac", now: t0)
        var phone = NotificationCoordinator(role: .iphone)
        _ = phone.cycle(ledger: &ledger, newEvents: [event("e", at: t0)], healthy: true, device: "iPhone", now: t0)
        let later = phone.cycle(ledger: &ledger, newEvents: [], healthy: true, device: "iPhone", now: t0.addingTimeInterval(30 * 3600))
        XCTAssertTrue(later.deliver.isEmpty, "a day later it is no longer news")
    }

    func testMergeKeepsNewestHeartbeatAndEveryEvent() {
        var a = NotificationLedger(), b = NotificationLedger()
        a.heartbeat(.mac, healthy: true, device: "Mac", now: t0)
        b.heartbeat(.mac, healthy: false, device: "Mac", now: t0.addingTimeInterval(60))
        a.record(["x"], by: .mac, now: t0)
        b.record(["x"], by: .iphone, now: t0.addingTimeInterval(30))
        b.record(["y"], by: .iphone, now: t0)
        a.merge(b)
        XCTAssertEqual(a.checkers[.mac]?.healthy, false)
        XCTAssertEqual(a.reportedBy["x"], .mac, "the first announcement counts")
        XCTAssertTrue(a.isReported("y"))
    }

    func testFileRoundTripAndConcurrentWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = LedgerFile(folder: dir)
        try file.update { $0.record(["one"], by: .mac, now: t0) }
        // A second device wrote the file after this one read it.
        var stale = file.read()
        try file.update { $0.record(["two"], by: .iphone, now: t0) }
        stale.record(["three"], by: .mac, now: t0)
        try file.update { $0.merge(stale) }
        let l = file.read()
        XCTAssertEqual(Set(l.reported.keys), ["one", "two", "three"])
        XCTAssertEqual(l.reportedBy["two"], .iphone)
    }

    func testPruneForgetsOldEvents() {
        var l = NotificationLedger()
        l.record(["old"], by: .mac, now: t0)
        l.record(["new"], by: .mac, now: t0.addingTimeInterval(13 * 86400))
        l.prune(now: t0.addingTimeInterval(15 * 86400))
        XCTAssertEqual(Set(l.reported.keys), ["new"])
    }
}

final class WatchCheckTests: XCTestCase {
    let nasdaq = ExchangeCatalog()["XNAS"]!

    func utc(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .utc
        return cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    func snapshot(confirmOnClose: Bool) -> (WatchSnapshot, WatchSnapshot.Row) {
        let p = Position(name: "Alico", isin: "US0162301040", listing: Listing(exchangeID: "XNAS", ticker: "ALCO"))
        let row = WatchSnapshot.Row(id: p.id, name: p.name, isin: p.isin, wkn: nil, assetType: .stock, listing: p.listing, exchangeBadge: "NSDQ",
                                    currency: "USD", held: true, state: .green, fresh: false, distance: 1, line: 37, price: 37.4, priceEUR: 32,
                                    quoteTime: utc(26, 20), eurPerUnit: 0.9, crossingDay: nil, crossingDown: nil, above: true, stale: false)
        var rules = RuleSet()
        rules.confirmOnClose = confirmOnClose
        let watchRules = rules.rules.filter { $0.enabled && $0.notify && $0.condition.a == .price && $0.condition.b == rules.ampel.line
            && ($0.condition.kind == .crossesBelow || $0.condition.kind == .crossesAbove) }
        let s = WatchSnapshot(rows: [row], createdAt: utc(26, 21), depotValueEUR: nil, ampel: rules.ampel, rules: watchRules,
                              confirmOnClose: confirmOnClose, exchanges: [], sources: SourcePreferences(), ledger: NotificationLedger())
        return (s, row)
    }

    func testCrossingBelowGivesTheSameIdAsOnTheMac() {
        var (s, row) = snapshot(confirmOnClose: false)
        let q = Quote(price: 36.5, time: utc(27, 20), previousClose: 37.4, currency: "USD", source: .yahoo)
        let events = WatchCheck.apply(q, to: &row, snapshot: s, exchange: nasdaq, now: utc(27, 20, 30))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, "\(row.id.uuidString)|\(RuleSet.crossDownID)|\(DayKey(iso: "2026-10-27")!.value)")
        XCTAssertEqual(events.first?.title, "Alico: fällt unter die 200-Tage-Linie")
        XCTAssertEqual(row.state, .red)
        XCTAssertEqual(row.above, false)
        // The same price again is no new crossing.
        s.rows = [row]
        XCTAssertTrue(WatchCheck.apply(q, to: &row, snapshot: s, exchange: nasdaq, now: utc(27, 21)).isEmpty)
    }

    func testClosingPricesOnlyWaitWhileTrading() {
        var (s, row) = snapshot(confirmOnClose: true)
        let q = Quote(price: 36.5, time: utc(27, 17), previousClose: 37.4, currency: "USD", source: .yahoo)
        XCTAssertTrue(WatchCheck.apply(q, to: &row, snapshot: s, exchange: nasdaq, now: utc(27, 17)).isEmpty, "Nasdaq open")
        XCTAssertEqual(row.above, true, "side not confirmed yet")
        s.rows = [row]
        let close = Quote(price: 36.4, time: utc(27, 20), previousClose: 37.4, currency: "USD", source: .yahoo)
        XCTAssertEqual(WatchCheck.apply(close, to: &row, snapshot: s, exchange: nasdaq, now: utc(27, 21)).count, 1)
    }

    func testWrongCurrencyOrJumpIsIgnored() {
        var (s, row) = snapshot(confirmOnClose: false)
        XCTAssertTrue(WatchCheck.apply(Quote(price: 30, time: utc(27, 20), previousClose: nil, currency: "EUR", source: .onvista),
                                       to: &row, snapshot: s, exchange: nasdaq, now: utc(27, 21)).isEmpty)
        s.rows = [row]
        XCTAssertTrue(WatchCheck.apply(Quote(price: 20, time: utc(27, 20), previousClose: nil, currency: "USD", source: .yahoo),
                                       to: &row, snapshot: s, exchange: nasdaq, now: utc(27, 21)).isEmpty, "50 % jump waits for a second source")
    }

    func testSnapshotRoundTrip() throws {
        let (s, _) = snapshot(confirmOnClose: false)
        let back = try WatchSnapshot.decode(try s.encoded())
        XCTAssertEqual(back.rows, s.rows)
        XCTAssertEqual(back.rules.count, 2)
    }
}
