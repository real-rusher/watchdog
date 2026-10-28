import Foundation
import WatchdogCore

/// One sentence that says what to do, and the numbers behind it. Same wording on Mac, iPhone and iPad.
enum Verdict {
    static func text(_ m: PositionMetrics?, rules: RuleSet) -> (title: String, detail: String) {
        let lineName = rules.ampel.line.description
        guard let m, let d = m.ampel.distancePercent, let lv = m.lineValues[rules.ampel.line] else {
            return ("Noch keine Aussage möglich", "Für die \(lineName) werden mindestens \(rules.ampel.line.length) Handelstage Kursverlauf gebraucht.")
        }
        let lineEUR = (m.priceEUR ?? 0) / max(m.priceLocal ?? 1, 0.0000001) * lv
        let base = "\(Format.pct(abs(d))) \(d >= 0 ? "über" : "unter") der \(lineName) (\(Format.eur(lineEUR)))."
        var cross = ""
        if let c = m.ampel.lastCrossing {
            cross = " Zuletzt nach \(c.direction == .down ? "unten" : "oben") gekreuzt am \(Format.day(c.day))"
            cross += c.sessionsAgo == 0 ? ", heute." : c.sessionsAgo == 1 ? ", vor einem Handelstag." : ", vor \(c.sessionsAgo) Handelstagen."
        }
        switch m.ampel.state {
        case .red: return (m.ampel.isFresh ? "Gerade unter die Linie gefallen. Hinschauen." : "Unter der Linie. Hinschauen.", base + cross)
        case .yellow: return ("Knapp an der Linie. Beobachten.", base + cross)
        case .green: return (m.ampel.isFresh ? "Gerade über die Linie gestiegen." : "Über der Linie. Kein dringender Handlungsbedarf.", base + cross)
        case .unknown: return ("Noch keine Aussage möglich", base)
        }
    }

    static func currencyName(_ c: String) -> String {
        switch c {
        case "USD": return "US-Dollar"
        case "JPY": return "Yen"
        case "GBP": return "Pfund"
        case "CHF": return "Franken"
        case "CAD": return "kanad. Dollar"
        case "AUD": return "austral. Dollar"
        case "NOK": return "norw. Kronen"
        case "SEK": return "schwed. Kronen"
        case "DKK": return "dän. Kronen"
        case "HKD": return "HK-Dollar"
        default: return c
        }
    }
}
