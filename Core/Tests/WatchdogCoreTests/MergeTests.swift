import XCTest
@testable import WatchdogCore

final class MergeTests: XCTestCase {
    func pos(_ name: String, bank: UUID? = nil) -> Position {
        Position(name: name, listing: Listing(exchangeID: "XETR", ticker: String(name.prefix(3)).uppercased()), bankID: bank)
    }

    func testBothDevicesEditDifferentValues() {
        let a = pos("Alpha"), b = pos("Beta")
        let base = DepotFile(positions: [a, b])
        var mine = base, theirs = base
        mine.positions[0].note = "vom iPhone"
        theirs.positions[1].note = "vom Mac"
        let m = DepotMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(m.positions.map(\.note), ["vom iPhone", "vom Mac"])
    }

    func testAddedOnBothDevicesKeepsBoth() {
        let a = pos("Alpha")
        let base = DepotFile(positions: [a])
        var mine = base, theirs = base
        mine.positions.append(pos("Neu iPhone"))
        theirs.positions.append(pos("Neu Mac"))
        let m = DepotMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(m.positions.map(\.name), ["Alpha", "Neu Mac", "Neu iPhone"])
    }

    func testDeletedHereStaysDeletedAndDeletedThereIsNotRevived() {
        let a = pos("Alpha"), b = pos("Beta"), c = pos("Gamma")
        let base = DepotFile(positions: [a, b, c])
        var mine = base, theirs = base
        mine.positions.removeAll { $0.id == a.id }      // deleted on this device
        theirs.positions.removeAll { $0.id == b.id }    // deleted on the other one
        let m = DepotMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(m.positions.map(\.name), ["Gamma"])
    }

    func testChangedHereButDeletedThereComesBack() {
        let a = pos("Alpha")
        let base = DepotFile(positions: [a])
        var mine = base
        mine.positions[0].note = "geändert"
        let theirs = DepotFile(positions: [])
        let m = DepotMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(m.positions.first?.note, "geändert")
    }

    func testSameValueChangedOnBothTakesThisDevice() {
        let a = pos("Alpha")
        let base = DepotFile(positions: [a])
        var mine = base, theirs = base
        mine.positions[0].note = "später"
        theirs.positions[0].note = "früher"
        XCTAssertEqual(DepotMerge.merge(base: base, mine: mine, theirs: theirs).positions[0].note, "später")
    }

    func testSettingsBlocksAndBanks() {
        let bank = Bank(name: "Comdirect", sortIndex: 0)
        let a = pos("Alpha", bank: bank.id)
        let base = DepotFile(positions: [a], banks: [bank])
        var mine = base, theirs = base
        mine.notifications.ntfyEnabled = true            // changed on the Mac
        theirs.rules.ampel.yellowBandPercent = 3         // changed elsewhere
        theirs.banks = []                                // bank deleted elsewhere
        let m = DepotMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertTrue(m.notifications.ntfyEnabled)
        XCTAssertEqual(m.rules.ampel.yellowBandPercent, 3)
        XCTAssertTrue(m.banks.isEmpty)
        XCTAssertNil(m.positions[0].bankID, "no reference to a deleted bank")
    }

    func testSaveMergingWithTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DepotStore(url: dir.appendingPathComponent("Watchdog.json"))
        let a = pos("Alpha")
        try store.save(DepotFile(positions: [a]))
        let base = try store.load()
        // The other device adds a value and saves.
        var other = base
        other.positions.append(pos("Vom Mac"))
        try store.save(other)
        // This device, still on the old base, edits Alpha and saves.
        var mine = base
        mine.positions[0].note = "vom iPhone"
        let written = try store.saveMerging(mine, base: base)
        XCTAssertEqual(written.positions.map(\.name), ["Alpha", "Vom Mac"])
        XCTAssertEqual(try store.load().positions.first?.note, "vom iPhone")
    }
}
