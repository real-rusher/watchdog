import Foundation

/// Is the data behind a row current? Answers "do I see real, up-to-date numbers or has a source gone quiet?"
public struct Freshness: Hashable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        /// Everything as expected.
        case ok
        /// Nothing fetched yet (first start, new position).
        case pending
        /// Data arrives, but the market has not traded the security today (or only a closing price is available).
        case noTradeToday
        /// Data should have arrived but did not: a source is down, throttling or the symbol stopped working.
        case stale
        /// No data at all although Watchdog tried.
        case missing

        public static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
    }

    public var level: Level
    /// Short text for the table (e.g. "seit 14:05 keine Kurse").
    public var headline: String
    /// Longer explanation with the error messages of the sources.
    public var detail: String
    public var lastSuccess: Date?

    public var isProblem: Bool { level >= .stale }

    public init(level: Level, headline: String, detail: String, lastSuccess: Date?) {
        self.level = level
        self.headline = headline
        self.detail = detail
        self.lastSuccess = lastSuccess
    }

    public static let ok = Freshness(level: .ok, headline: "", detail: "", lastSuccess: nil)
}

public enum FreshnessCheck {
    /// - Parameters:
    ///   - interval: the configured quote refresh interval in seconds.
    public static func evaluate(exchange: Exchange, quote: Quote?, lastBarDay: DayKey?, status: ListingStatus?,
                                currency: String, fxLatest: DayKey?, interval: TimeInterval, now: Date = Date()) -> Freshness {
        let lastSuccess = [quote?.fetchedAt, status?.lastQuoteSuccess].compactMap { $0 }.max()
        let errorText = status?.lastError.map { "\n" + $0 } ?? ""

        if quote == nil && lastBarDay == nil {
            let tried = status?.lastQuoteAttempt != nil || status?.lastError != nil
            if !tried || status?.isLoading == true {
                return Freshness(level: .pending, headline: "lädt", detail: "Kurse werden geladen.", lastSuccess: nil)
            }
            return Freshness(level: .missing, headline: "keine Kurse",
                             detail: "Keine der Datenquellen liefert Kurse für diesen Wert." + errorText, lastSuccess: nil)
        }

        var level = Freshness.Level.ok
        var headline = ""
        var details: [String] = []
        func raise(_ l: Freshness.Level, _ h: String, _ d: String) {
            if l > level { level = l; headline = h }
            details.append(d)
        }

        let tz = exchange.tz
        let today = DayKey(date: now, timeZone: tz)
        let allowed = max(3 * interval, 45 * 60)

        // 1) Current price.
        if exchange.kind == .crypto || exchange.isOpen(at: now) {
            let openFor = exchange.kind == .crypto ? Double.infinity : Double(exchange.minutesSinceOpen(at: now) ?? 0) * 60
            if openFor > allowed, lastSuccess.map({ now.timeIntervalSince($0) > allowed }) ?? true {
                let since = lastSuccess.map { Format.time($0) } ?? "Start"
                raise(.stale, "seit \(since) keine Kurse",
                      "Die Börse ist geöffnet, aber seit \(since) kam kein neuer Kurs. Signale für diesen Wert sind solange nicht aktuell.")
            } else if let q = quote, exchange.kind != .crypto, openFor > 90 * 60, DayKey(date: q.time, timeZone: tz) < today {
                raise(.noTradeToday, "kein Kurs von heute",
                      "Heute gibt es noch keinen Kurs (letzter: \(Format.time(q.time)), Quelle \(q.source.displayName)). Entweder wurde noch nicht gehandelt oder die Quelle liefert nur Schlusskurse.")
            }
        } else {
            let session = exchange.lastCompletedSession(at: now)
            let close = ProviderUtil.closeTime(session, exchange)
            if now.timeIntervalSince(close) > 3 * 3600 {
                let quoteDay = quote.map { DayKey(date: $0.time, timeZone: tz) }
                let haveClose = (quoteDay.map { $0 >= session } ?? false) || (lastBarDay.map { $0 >= session } ?? false)
                if !haveClose {
                    if let ls = lastSuccess, ls > close.addingTimeInterval(600) {
                        raise(.noTradeToday, "kein Handel am \(Format.dayShort(session))",
                              "Die Quelle antwortet, meldet für den \(Format.day(session)) aber keinen Kurs (vermutlich kein Handel).")
                    } else {
                        raise(.stale, "Schlusskurs \(Format.dayShort(session)) fehlt",
                              "Der Schlusskurs vom \(Format.day(session)) ist nicht angekommen.")
                    }
                }
            }
        }

        // 2) Daily history, the basis of the 200-day line.
        if let last = lastBarDay {
            let expected = exchange.lastCompletedSession(at: now)
            let missing = exchange.sessions(after: last, upTo: expected)
            if missing >= (exchange.kind == .crypto ? 2 : 3) {
                raise(.stale, "Verlauf endet \(Format.dayShort(last))",
                      "Der Kursverlauf endet am \(Format.day(last)); \(missing) Handelstage fehlen. Die 200-Tage-Linie ist dadurch nicht aktuell.")
            }
        }

        // 3) Exchange rate for the conversion to EUR.
        if currency != "EUR" {
            let todayBerlin = DayKey(date: now, timeZone: .berlin)
            if let fx = fxLatest {
                if fx.days(to: todayBerlin) > 5 {
                    raise(.stale, "Wechselkurs \(currency) alt", "Der Wechselkurs \(currency) zu Euro ist vom \(Format.day(fx)); Euro-Werte können abweichen.")
                }
            } else {
                raise(.stale, "Wechselkurs \(currency) fehlt", "Für \(currency) liegt kein Wechselkurs vor; Euro-Werte können nicht berechnet werden.")
            }
        }

        if level >= .stale { details.append(contentsOf: status?.lastError.map { [$0] } ?? []) }
        return Freshness(level: level, headline: headline, detail: details.joined(separator: "\n"), lastSuccess: lastSuccess)
    }
}

/// What a source has to deliver to count as current. An older answer does not end the search for data:
/// the next sources are asked, and the newest answer of all is used.
public enum Currentness {
    /// A quote at or after this time is current.
    /// While the venue trades: not older than the stale limit (3 intervals, at least 45 minutes).
    /// Otherwise, and shortly after the open: the close of the last completed session.
    public static func quoteDue(_ exchange: Exchange, interval: TimeInterval, now: Date = Date()) -> Date {
        let allowed = max(3 * interval, 45 * 60)
        if exchange.kind == .crypto { return now.addingTimeInterval(-allowed) }
        if exchange.isOpen(at: now), Double(exchange.minutesSinceOpen(at: now) ?? 0) * 60 > allowed {
            return now.addingTimeInterval(-allowed)
        }
        return ProviderUtil.closeTime(exchange.lastCompletedSession(at: now), exchange).addingTimeInterval(-60)
    }

    /// The last daily bar a current history ends with. Sources get three hours after the close to publish it.
    public static func historyDue(_ exchange: Exchange, now: Date = Date()) -> DayKey {
        exchange.lastCompletedSession(at: now.addingTimeInterval(-3 * 3600))
    }
}
