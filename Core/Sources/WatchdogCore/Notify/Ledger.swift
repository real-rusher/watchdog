import Foundation

/// The devices that check prices, in the order in which they are on duty for notifications.
public enum CheckerRole: String, Codable, CaseIterable, Comparable, Sendable {
    case mac
    case iphone
    case watch

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .iphone: return "iPhone"
        case .watch: return "Apple Watch"
        }
    }

    public static func < (l: CheckerRole, r: CheckerRole) -> Bool {
        allCases.firstIndex(of: l)! < allCases.firstIndex(of: r)!
    }
}

/// Shared between Mac, iPhone and Watch ("Meldebuch", a small file next to the depot in iCloud Drive):
/// who checked prices when, and which events have been announced already.
///
/// The Mac is on duty. The iPhone only announces when the Mac's checks have stopped or fail,
/// the Watch only when both have. Every device skips events another one already announced.
public struct NotificationLedger: Codable, Hashable, Sendable {
    public struct Checker: Codable, Hashable, Sendable {
        /// Last completed check.
        public var lastCheck: Date
        /// The check delivered data for most values (a Mac without internet or with failing sources is not healthy).
        public var healthy: Bool
        /// Device name for the settings ("MacBook Pro von Martin").
        public var device: String

        public init(lastCheck: Date, healthy: Bool, device: String) {
            self.lastCheck = lastCheck
            self.healthy = healthy
            self.device = device
        }
    }

    public static let fileName = "Mitteilungen.json"
    /// A device whose last check is older than this has stopped checking; the next one takes over.
    /// Same limit as the outage message.
    public static let staleAfter: TimeInterval = 20 * 60
    /// Announced events are remembered this long.
    public static let keepDays = 14

    public var checkers: [CheckerRole: Checker] = [:]
    /// Event id (`SignalEvent.id`) and when it was announced.
    public var reported: [String: Date] = [:]
    /// Who announced an event, for the event log.
    public var reportedBy: [String: CheckerRole] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case checkers, reported, reportedBy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decode([String: Checker].self, forKey: .checkers)) ?? [:]
        checkers = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in CheckerRole(rawValue: k).map { ($0, v) } })
        reported = (try? c.decode([String: Date].self, forKey: .reported)) ?? [:]
        let by = (try? c.decode([String: String].self, forKey: .reportedBy)) ?? [:]
        reportedBy = by.compactMapValues { CheckerRole(rawValue: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: checkers.map { ($0.key.rawValue, $0.value) }), forKey: .checkers)
        try c.encode(reported, forKey: .reported)
        try c.encode(reportedBy.mapValues(\.rawValue), forKey: .reportedBy)
    }

    // MARK: Rules

    /// Whether a device currently checks prices successfully.
    public func isActive(_ role: CheckerRole, now: Date = Date()) -> Bool {
        guard let c = checkers[role] else { return false }
        return c.healthy && now.timeIntervalSince(c.lastCheck) < Self.staleAfter
    }

    /// The device that announces events now: the first one in the order Mac, iPhone, Watch that checks successfully.
    /// `asking` counts as active (it is checking right now), so a device never waits for a successor.
    public func onDuty(asking role: CheckerRole, healthy: Bool = true, now: Date = Date()) -> CheckerRole {
        for r in CheckerRole.allCases {
            if r == role { return healthy ? r : (CheckerRole.allCases.first { $0 > r && isActive($0, now: now) } ?? r) }
            if isActive(r, now: now) { return r }
        }
        return role
    }

    public func isReported(_ id: String) -> Bool { reported[id] != nil }

    // MARK: Changes

    public mutating func heartbeat(_ role: CheckerRole, healthy: Bool, device: String, now: Date = Date()) {
        checkers[role] = Checker(lastCheck: now, healthy: healthy, device: device)
    }

    public mutating func record(_ ids: [String], by role: CheckerRole, now: Date = Date()) {
        for id in ids where reported[id] == nil {
            reported[id] = now
            reportedBy[id] = role
        }
    }

    /// Combines two copies (another device may have written in between): newest heartbeat per device,
    /// every announced event with its earliest time.
    public mutating func merge(_ other: NotificationLedger) {
        for (role, c) in other.checkers where (checkers[role]?.lastCheck ?? .distantPast) < c.lastCheck { checkers[role] = c }
        for (id, t) in other.reported {
            if let mine = reported[id], mine <= t { continue }
            reported[id] = t
            if let by = other.reportedBy[id] { reportedBy[id] = by }
        }
    }

    public mutating func prune(now: Date = Date()) {
        let limit = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
        reported = reported.filter { $0.value >= limit }
        reportedBy = reportedBy.filter { reported[$0.key] != nil }
    }
}

/// One device's part of the notification duty: keeps events it could not announce yet and decides what to send.
public struct NotificationCoordinator: Codable, Sendable {
    public var role: CheckerRole
    /// Events this device noticed while another one was on duty. Announced later if nobody else did.
    public var pending: [SignalEvent] = []
    /// Events older than this are no longer news.
    public static let pendingLimit: TimeInterval = 24 * 3600

    public init(role: CheckerRole) { self.role = role }

    public struct Decision: Sendable {
        /// Events to show and send now.
        public var deliver: [SignalEvent]
        /// Device announcing at the moment.
        public var onDuty: CheckerRole
    }

    /// One round after a check: writes the heartbeat into `ledger`, takes the new events and returns what this device announces.
    public mutating func cycle(ledger: inout NotificationLedger, newEvents: [SignalEvent], healthy: Bool, device: String,
                               now: Date = Date()) -> Decision {
        ledger.heartbeat(role, healthy: healthy, device: device, now: now)
        ledger.prune(now: now)
        var seen = Set(pending.map(\.id))
        for e in newEvents where !seen.contains(e.id) {
            pending.append(e)
            seen.insert(e.id)
        }
        pending = pending.filter { !ledger.isReported($0.id) && now.timeIntervalSince($0.createdAt) < Self.pendingLimit }
        let duty = ledger.onDuty(asking: role, healthy: healthy, now: now)
        guard duty == role else { return Decision(deliver: [], onDuty: duty) }
        let out = pending
        ledger.record(out.map(\.id), by: role, now: now)
        pending = []
        return Decision(deliver: out, onDuty: duty)
    }
}

/// Reads and writes the ledger next to the depot file. Every write merges with what is on disk,
/// so two devices writing at nearly the same time lose nothing.
public struct LedgerFile: Sendable {
    public let url: URL

    public init(folder: URL) { url = folder.appendingPathComponent(NotificationLedger.fileName) }

    public func read() -> NotificationLedger {
        guard let data = try? Data(contentsOf: url) else { return NotificationLedger() }
        return (try? DepotStore.decoder().decode(NotificationLedger.self, from: data)) ?? NotificationLedger()
    }

    /// Reads the current file, lets `change` work on it and writes the result.
    @discardableResult
    public func update<T>(_ change: (inout NotificationLedger) -> T) throws -> T {
        var l = read()
        let result = change(&l)
        // Another device may have written meanwhile.
        l.merge(read())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DepotStore.encoder().encode(l).write(to: url, options: [.atomic])
        return result
    }
}
