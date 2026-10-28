import Foundation
import WatchdogCore

/// Access to the "Watchdog" folder in iCloud Drive that the Mac app writes.
/// An iPhone app may only open folders the user picked once; the choice is kept as a bookmark.
enum DepotAccess {
    private static let bookmarkKey = "depotFolderBookmark"
    static let depotName = "Watchdog.json"

    enum Problem: LocalizedError {
        case noDepot
        var errorDescription: String? {
            "In diesem Ordner liegt keine Datei \u{201E}\(DepotAccess.depotName)\u{201C}. Bitte den Ordner \u{201E}Watchdog\u{201C} in iCloud Drive wählen, den die Mac-App angelegt hat."
        }
    }

    /// Keeps the picked folder for later starts.
    static func remember(_ folder: URL) throws {
        _ = folder.startAccessingSecurityScopedResource()
        let data = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { try? remember(url) }
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Reads the depot. iCloud may not have downloaded the newest version yet; it is requested and read as soon as it is there.
    static func readDepot(in folder: URL) throws -> DepotFile {
        let file = folder.appendingPathComponent(depotName)
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        var result: Result<DepotFile, Error> = .failure(Problem.noDepot)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            result = Result { try DepotStore(url: url).load() }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// Reads and writes the shared ledger ("Mitteilungen.json") without overwriting what the Mac wrote at the same moment.
    static func updateLedger<T>(in folder: URL, _ change: (inout NotificationLedger) -> T) -> (T, NotificationLedger)? {
        let file = LedgerFile(folder: folder)
        try? FileManager.default.startDownloadingUbiquitousItem(at: file.url)
        var out: (T, NotificationLedger)?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file.url, options: .forMerging, error: &coordError) { url in
            let f = LedgerFile(folder: url.deletingLastPathComponent())
            var copy = NotificationLedger()
            if let r = try? f.update({ (l: inout NotificationLedger) -> T in
                let r = change(&l)
                copy = l
                return r
            }) {
                out = (r, copy)
            }
        }
        return coordError == nil ? out : nil
    }
}
