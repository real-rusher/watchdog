import Foundation
import WatchdogCore

/// Settings that stay on this Mac (not synced with the depot file).
struct LocalSettings: Codable, Equatable {
    var depotPath: String?
    var apiKeys: [String: String] = [:]
    var quoteIntervalMinutes: Int = 15
    var fontScale: Double = 1.0
    var grouping: Grouping = .bank
    var sort: SortKey = .signal
    var sortAscending = true
    var showInDock = true
    var hiddenColumns: Set<String> = []
    var defaultImportExchange: String = "TGAT"
    var collapsedSections: Set<String> = []
    var hasCompletedSetup = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LocalSettings()
        depotPath = c.value(.depotPath, d.depotPath)
        apiKeys = c.value(.apiKeys, d.apiKeys)
        quoteIntervalMinutes = c.value(.quoteIntervalMinutes, d.quoteIntervalMinutes)
        fontScale = c.value(.fontScale, d.fontScale)
        grouping = c.value(.grouping, d.grouping)
        sort = c.value(.sort, d.sort)
        sortAscending = c.value(.sortAscending, d.sortAscending)
        showInDock = c.value(.showInDock, d.showInDock)
        hiddenColumns = c.value(.hiddenColumns, d.hiddenColumns)
        defaultImportExchange = c.value(.defaultImportExchange, d.defaultImportExchange)
        collapsedSections = c.value(.collapsedSections, d.collapsedSections)
        hasCompletedSetup = c.value(.hasCompletedSetup, d.hasCompletedSetup)
    }

    var keys: [ProviderID: String] {
        var out: [ProviderID: String] = [:]
        for (k, v) in apiKeys {
            if let p = ProviderID(rawValue: k), !v.trimmingCharacters(in: .whitespaces).isEmpty { out[p] = v }
        }
        return out
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Watchdog", isDirectory: true)
    }

    static var fileURL: URL { supportDir.appendingPathComponent("settings.json") }

    static func load() -> LocalSettings {
        guard let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(LocalSettings.self, from: data) else { return LocalSettings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: LocalSettings.supportDir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(self) {
            try? data.write(to: LocalSettings.fileURL, options: [.atomic])
            // API keys are personal: owner-only file permissions.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: LocalSettings.fileURL.path)
        }
    }
}

enum SortKey: String, Codable, CaseIterable {
    case signal, name, value, day, sincePurchase, ytd, days30, distance

    var label: String {
        switch self {
        case .signal: return "Signal"
        case .name: return "Name"
        case .value: return "Wert"
        case .day: return "Heute"
        case .sincePurchase: return "Seit Kauf"
        case .ytd: return "Seit 1.1."
        case .days30: return "30 Tage"
        case .distance: return "Abstand 200er"
        }
    }
}
