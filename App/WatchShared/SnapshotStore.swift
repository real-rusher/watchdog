import Foundation
import WatchdogCore

/// The last reading on the Watch, shared between the Watch app and the complication (App Group once the apps are signed).
enum SnapshotStore {
    static let group = "group.de.realrusher.watchdog"

    static var url: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("watch-snapshot.json")
    }

    static func load() -> WatchSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? WatchSnapshot.decode(data)
    }

    static func save(_ s: WatchSnapshot) {
        guard let data = try? DepotStore.encoder().encode(s) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
