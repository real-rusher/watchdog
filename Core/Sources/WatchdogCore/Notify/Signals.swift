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
    /// Since when at least one value has had no current data (nil = all fine).
    public var quietSince: Date?
    /// Day of the last "data missing" message (at most one per day).
    public var dataAlertDay: DayKey?

    public init() {}

    enum CodingKeys: String, CodingKey { case notified, active, firstSeen, log, quietSince, dataAlertDay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notified = c.value(.notified, [])
        active = c.value(.active, [])
        firstSeen = c.value(.firstSeen, [:])
        log = c.value(.log, [])
        quietSince = c.value(.quietSince, nil as Date?)
        dataAlertDay = c.value(.dataAlertDay, nil as DayKey?)
    }

    public static let dataAlertID = UUID(uuidString: "0B5E0C1A-2000-4000-8000-0000000000DA")!

    /// One message when values have gone without data for 20 minutes, at most once per day.
    public mutating func processOutage(_ quiet: [(name: String, headline: String)], enabled: Bool,
                                       now: Date = Date(), minimum: TimeInterval = 20 * 60) -> SignalEvent? {
        guard !quiet.isEmpty else {
            quietSince = nil
            return nil
        }
        if quietSince == nil { quietSince = now }
        let today = DayKey(date: now, timeZone: .berlin)
        guard enabled, let since = quietSince, now.timeIntervalSince(since) >= minimum, dataAlertDay != today else { return nil }
        dataAlertDay = today
        let names = quiet.prefix(4).map { "\($0.name) (\($0.headline))" }.joined(separator: ", ")
        let more = quiet.count > 4 ? " und \(quiet.count - 4) weitere" : ""
        let count = quiet.count == 1 ? "1 Wert" : "\(quiet.count) Werte"
        let e = SignalEvent(id: "data|\(today.value)", positionID: Self.dataAlertID, positionName: "Datenquellen", exchangeName: "",
                            ruleName: "Kurse bleiben aus", severity: .warning, day: today,
                            title: "Watchdog: Kurse bleiben aus",
                            body: "Keine aktuellen Daten für \(count): \(names)\(more). Ampel und Signale dieser Werte sind bis dahin nicht aktuell.",
                            createdAt: now)
        log = Array(([e] + log).prefix(300))
        return e
    }

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
        var lineEUR: Double?
        if let line = metrics.lineValues[hit.rule.condition.b], hit.rule.condition.kind.usesLines, hit.rule.condition.b != .price,
           let pl = metrics.priceLocal, pl > 0, let pe = metrics.priceEUR {
            lineEUR = line * pe / pl
        }
        return Self.event(id: key, rule: hit.rule, day: day, position: position, exchange: exchange, priceEUR: metrics.priceEUR,
                          lineEUR: lineEUR, distance: metrics.ampel.distancePercent)
    }

    /// Message text, short enough for the Apple Watch: what happened in the title, the numbers in the body.
    /// No amounts or quantities of the holding.
    public static func event(id: String, rule: Rule, day: DayKey, position: Position, exchange: Exchange, priceEUR: Double?,
                             lineEUR: Double?, distance: Double?, now: Date = Date()) -> SignalEvent {
        var facts: [String] = []
        if let p = priceEUR { facts.append("Kurs \(Format.eur(p))") }
        if let l = lineEUR { facts.append("\(rule.condition.b.longLabel) \(Format.eur(l))") }
        if let d = distance { facts.append("Abstand \(Format.pct(d, signed: true))") }
        facts.append(exchange.name)
        if rule.condition.kind.isEvent { facts.append(Format.dayShort(day)) }
        return SignalEvent(id: id, positionID: position.id, positionName: position.name, exchangeName: exchange.name,
                           ruleName: rule.name, severity: rule.severity, day: day, title: "\(position.name): \(rule.headline)",
                           body: facts.joined(separator: " · "), createdAt: now)
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
        // Tapping the message opens the value in the iPhone app once it is installed.
        let click = settings.ntfyOpensApp && e.positionID != SignalState.dataAlertID ? "watchdog://wert/\(e.positionID.uuidString)" : nil
        try await send(title: e.title, body: e.body, severity: e.severity, click: click)
    }

    public func send(title: String, body: String, severity: Severity, click: String? = nil) async throws {
        guard let base = settings.subscribeURL else { throw ProviderError.parse("ntfy URL") }
        // Title, priority and tags as query parameters: UTF-8 safe (umlauts), unlike raw HTTP headers.
        var query: [(String, String)] = [
            ("title", title),
            ("priority", severity == .alarm ? "high" : severity == .warning ? "default" : "low"),
            ("tags", severity == .alarm ? "red_circle,chart_with_downwards_trend" : severity == .warning ? "yellow_circle" : "green_circle,chart_with_upwards_trend"),
        ]
        if let click { query.append(("click", click)) }
        let url = URL.make(base.absoluteString, query)
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
    private static let f3 = nf(2, 3)
    private static let fQty = nf(0, 6)

    /// Prices: small values get more decimals (penny stocks, crypto fractions), always three significant digits.
    public static func number(_ v: Double, decimals: Int? = nil) -> String {
        if let d = decimals { return nf(d, d).string(from: NSNumber(value: v)) ?? "\(v)" }
        let a = abs(v)
        if a > 0 && a < 0.01 {
            let digits = min(8, Int((-log10(a)).rounded(.down)) + 3)
            var t = String(format: "%.\(digits)f", v)
            while t.hasSuffix("0"), let dot = t.firstIndex(of: "."), t.distance(from: dot, to: t.endIndex) > 3 { t.removeLast() }
            return t.replacingOccurrences(of: ".", with: ",")
        }
        // Below 10 the third decimal is often quoted (6,275 €); it is shown so values match the exchange exactly.
        let f = a >= 10 ? f2 : a >= 1 ? f3 : f4
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
