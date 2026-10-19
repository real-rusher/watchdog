import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A rule that fired and should be announced.
public struct SignalEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var positionID: UUID
    public var positionName: String
    public var exchangeName: String
    public var ruleName: String
    public var severity: Severity
    public var day: DayKey
    public var title: String
    public var body: String
    public var createdAt: Date
}

/// Remembers what was announced so nothing is sent twice and nothing is sent for old events on first start.
public struct SignalState: Codable, Sendable {
    public var notified: Set<String> = []
    public var active: Set<String> = []
    /// First day a position was evaluated; events before it are history, not news.
    public var firstSeen: [String: DayKey] = [:]
    public var log: [SignalEvent] = []

    public init() {}

    /// Compares rule hits with the remembered state and returns new events.
    public mutating func process(metrics: PositionMetrics, position: Position, exchange: Exchange, rules: RuleSet, today: DayKey = DayKey.today(in: .berlin)) -> [SignalEvent] {
        guard metrics.hasData, metrics.historyCount >= 30 else { return [] }
        let pid = position.id.uuidString
        let isFirst = firstSeen[pid] == nil
        if isFirst { firstSeen[pid] = today }
        let start = firstSeen[pid] ?? today
        var events: [SignalEvent] = []
        var nowActive: Set<String> = []

        for hit in metrics.hits {
            let key = "\(pid)|\(hit.dedupKey)"
            if hit.rule.condition.kind.isEvent {
                guard let day = hit.eventDay else { continue }
                if notified.contains(key) { continue }
                notified.insert(key)
                // Crossings that happened before Watchdog watched this position are not news.
                if isFirst || day < start.adding(days: -1) { continue }
                if hit.rule.notify { events.append(makeEvent(key: key, hit: hit, day: day, metrics: metrics, position: position, exchange: exchange)) }
            } else {
                nowActive.insert(key)
                if active.contains(key) || isFirst { continue }
                if hit.rule.notify { events.append(makeEvent(key: key + "|\(today.value)", hit: hit, day: today, metrics: metrics, position: position, exchange: exchange)) }
            }
        }
        // State rules that are no longer true can fire again later.
        active = active.filter { !$0.hasPrefix(pid + "|") }.union(nowActive)
        log = Array((events + log).prefix(300))
        return events
    }

    /// Forget a deleted position.
    public mutating func forget(_ id: UUID) {
        let p = id.uuidString + "|"
        notified = notified.filter { !$0.hasPrefix(p) }
        active = active.filter { !$0.hasPrefix(p) }
        firstSeen[id.uuidString] = nil
    }

    private func makeEvent(key: String, hit: RuleHit, day: DayKey, metrics: PositionMetrics, position: Position, exchange: Exchange) -> SignalEvent {
        let title = "\(position.name) · \(exchange.name)"
        var parts: [String] = [hit.rule.name]
        if hit.rule.condition.kind.isEvent { parts[0] += " am \(Format.dayShort(day))" }
        var facts: [String] = []
        if let p = metrics.priceEUR { facts.append("Kurs \(Format.eur(p))") }
        if let line = metrics.lineValues[hit.rule.condition.b], hit.rule.condition.kind.usesLines, hit.rule.condition.b != .price,
           let pl = metrics.priceLocal, pl > 0, let pe = metrics.priceEUR {
            facts.append("\(hit.rule.condition.b.shortLabel) \(Format.eur(line * pe / pl))")
        }
        if let d = metrics.ampel.distancePercent { facts.append("Abstand \(Format.pct(d, signed: true))") }
        parts += facts
        return SignalEvent(id: key, positionID: position.id, positionName: position.name, exchangeName: exchange.name,
                           ruleName: hit.rule.name, severity: hit.rule.severity, day: day, title: title,
                           body: parts.joined(separator: " · "), createdAt: Date())
    }
}

/// Sends events to an ntfy topic (iPhone and Apple Watch via the ntfy app).
public struct NtfyNotifier: Sendable {
    public var settings: NotificationSettings
    public var http: HTTPClient

    public init(settings: NotificationSettings, http: HTTPClient) {
        self.settings = settings
        self.http = http
    }

    public func send(_ e: SignalEvent) async throws {
        try await send(title: e.title, body: e.body, severity: e.severity)
    }

    public func send(title: String, body: String, severity: Severity) async throws {
        guard let base = settings.subscribeURL else { throw ProviderError.parse("ntfy URL") }
        // Title, priority and tags as query parameters: UTF-8 safe (umlauts), unlike raw HTTP headers.
        let url = URL.make(base.absoluteString, [
            ("title", title),
            ("priority", severity == .alarm ? "high" : severity == .warning ? "default" : "low"),
            ("tags", severity == .alarm ? "red_circle,chart_with_downwards_trend" : severity == .warning ? "yellow_circle" : "green_circle,chart_with_upwards_trend"),
        ])
        var headers: [String: String] = [:]
        if let t = settings.ntfyToken, !t.isEmpty { headers["Authorization"] = "Bearer \(t)" }
        let (data, resp) = try await http.post(url, body: Data(body.utf8), contentType: "text/plain; charset=utf-8", headers: headers)
        try HTTPClient.check(resp, data)
    }

    static func rfc2047(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}

/// German number formatting used in messages and the UI.
public enum Format {
    private static func nf(_ min: Int, _ max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = min
        f.maximumFractionDigits = max
        f.usesGroupingSeparator = true
        return f
    }

    private static let f2 = nf(2, 2)
    private static let f1 = nf(1, 1)
    private static let f0 = nf(0, 0)
    private static let f4 = nf(2, 4)
    private static let fQty = nf(0, 6)

    /// Prices: small values get more decimals (penny stocks, crypto fractions).
    public static func number(_ v: Double, decimals: Int? = nil) -> String {
        if let d = decimals { return nf(d, d).string(from: NSNumber(value: v)) ?? "\(v)" }
        let a = abs(v)
        let f = a >= 1000 ? f2 : a >= 1 ? f2 : f4
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    public static func eur(_ v: Double, decimals: Int? = nil) -> String { number(v, decimals: decimals) + " €" }

    public static func money(_ v: Double, _ currency: String) -> String {
        currency == "EUR" ? eur(v) : number(v) + " " + CurrencyNormalizer.symbol(currency)
    }

    public static func pct(_ v: Double, signed: Bool = false) -> String {
        let s = (abs(v) >= 100 ? f0 : f1).string(from: NSNumber(value: v)) ?? "\(v)"
        return (signed && v > 0 ? "+" : "") + s + " %"
    }

    public static func signedEUR(_ v: Double) -> String { (v > 0 ? "+" : "") + eur(v, decimals: abs(v) >= 1000 ? 0 : 2) }

    public static func qty(_ v: Double) -> String { fQty.string(from: NSNumber(value: v)) ?? "\(v)" }

    public static func dayShort(_ d: DayKey) -> String { String(format: "%02d.%02d.", d.day, d.month) }
    public static func day(_ d: DayKey) -> String { String(format: "%02d.%02d.%04d", d.day, d.month, d.year) }

    public static func time(_ date: Date, tz: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = tz
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if Date().timeIntervalSince(date) < 6 * 86400 {
            f.dateFormat = "EE HH:mm"
        } else {
            f.dateFormat = "dd.MM.yy"
        }
        return f.string(from: date)
    }
}
