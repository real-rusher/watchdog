import Foundation

/// Reads and writes the depot file (normally in iCloud Drive) and keeps rolling backups next to it.
public final class DepotStore: @unchecked Sendable {
    public let url: URL
    public var backupsURL: URL { url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }
    private let fm = FileManager.default
    private var lastBackup: Date?

    public init(url: URL) { self.url = url }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// iCloud Drive folder on the Mac if it exists, otherwise Documents.
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let base: URL
        if FileManager.default.fileExists(atPath: icloud.path) {
            base = icloud.appendingPathComponent("Watchdog", isDirectory: true)
        } else {
            base = home.appendingPathComponent("Documents/Watchdog", isDirectory: true)
        }
        return base.appendingPathComponent("Watchdog.json")
    }

    public var exists: Bool { fm.fileExists(atPath: url.path) }

    public func modificationDate() -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func load() throws -> DepotFile {
        let data = try Data(contentsOf: url)
        return try DepotStore.decoder().decode(DepotFile.self, from: data)
    }

    public func save(_ depot: DepotFile) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = depot
        d.modifiedAt = Date()
        let data = try DepotStore.encoder().encode(d)
        try backupIfDue()
        try data.write(to: url, options: [.atomic])
    }

    /// Immediate backup of the file as it is now (before deleting many values at once).
    public func backupNow() {
        lastBackup = nil
        try? backupIfDue()
    }

    /// One backup per hour, the newest 60 are kept.
    private func backupIfDue() throws {
        guard exists else { return }
        if let last = lastBackup, Date().timeIntervalSince(last) < 3600 { return }
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        let target = backupsURL.appendingPathComponent("Watchdog_\(f.string(from: Date())).json")
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: url, to: target) }
        lastBackup = Date()
        let files = ((try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(60) { try? fm.removeItem(at: old) }
    }

    public func backups() -> [URL] {
        ((try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Writes a copy of the depot to `target` (export).
    public func export(_ depot: DepotFile, to target: URL) throws {
        try DepotStore.encoder().encode(depot).write(to: target, options: [.atomic])
    }
}

/// Local, non-synced cache: price histories, last quotes, resolved symbols, exchange rates, signal state.
public actor CacheStore {
    public let dir: URL
    private let fm = FileManager.default

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("history", isDirectory: true), withIntermediateDirectories: true)
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func historyURL(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return dir.appendingPathComponent("history", isDirectory: true).appendingPathComponent(safe + ".json")
    }

    public func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? DepotStore.decoder().decode(T.self, from: data)
    }

    public func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder.compact.encode(value) else { return }
        try? data.write(to: file(name), options: [.atomic])
    }

    public func loadHistories() -> [String: PriceHistory] {
        let hdir = dir.appendingPathComponent("history", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: hdir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: PriceHistory] = [:]
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let h = try? DepotStore.decoder().decode(PriceHistory.self, from: data) {
                out[h.listingKey] = h
            }
        }
        return out
    }

    public func saveHistory(_ h: PriceHistory) {
        guard let data = try? JSONEncoder.compact.encode(h) else { return }
        try? data.write(to: historyURL(h.listingKey), options: [.atomic])
    }

    public func removeHistory(_ key: String) {
        try? fm.removeItem(at: historyURL(key))
    }

    public func clearAll() {
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir.appendingPathComponent("history", isDirectory: true), withIntermediateDirectories: true)
    }
}

extension JSONEncoder {
    static var compact: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
