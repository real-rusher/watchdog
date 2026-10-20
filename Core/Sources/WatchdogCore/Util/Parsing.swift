import Foundation

/// Lenient number and date parsing for user input, CSV files and loosely typed API responses.
public enum Lenient {
    /// Parses "1.234,56", "1,234.56", "1234.56", "1234,56", "12 345,6", "-3,2 %" and similar.
    public static func double(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "EUR", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "'", with: "")
        if s.hasPrefix("+") { s.removeFirst() }
        let hasComma = s.contains(",")
        let hasDot = s.contains(".")
        if hasComma && hasDot {
            // The separator that appears last is the decimal separator.
            if let lc = s.lastIndex(of: ","), let ld = s.lastIndex(of: "."), lc > ld {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 2 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasDot {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            // "1.234.567" is a German thousands grouping; "1.234" stays ambiguous and is read as decimal.
            if parts.count > 2 { s = s.replacingOccurrences(of: ".", with: "") }
        }
        return Double(s)
    }

    /// German input: "1.000" means one thousand (dots followed by groups of three digits), "0.5" stays a decimal.
    public static func germanDouble(_ raw: String?) -> Double? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if !t.contains(","), t.contains("."), !t.hasPrefix("0"), !t.hasPrefix("-0") {
            let groups = t.replacingOccurrences(of: "-", with: "").split(separator: ".", omittingEmptySubsequences: false)
            if groups.count > 1, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) {
                return double(t.replacingOccurrences(of: ".", with: ""))
            }
        }
        return double(t)
    }

    /// Accepts numbers that arrive either as JSON numbers or as strings.
    public static func double(any value: Any?) -> Double? {
        switch value {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return double(s)
        default: return nil
        }
    }

    private static let dateFormats = ["dd.MM.yyyy", "d.M.yyyy", "dd.MM.yy", "d.M.yy", "yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "yyyy/MM/dd",
                                      "dd-MM-yyyy", "d/M/yyyy", "d/M/yy", "yyyyMMdd"]
    private static let wordFormats = ["d. MMMM yyyy", "d. MMM yyyy", "d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "MMM d, yyyy", "d-MMM-yyyy", "d-MMM-yy"]

    /// Dates like 04/03/2024: `monthFirst` true reads them the US way (3 April), false the European way (4 March).
    public static func day(_ raw: String?, monthFirst: Bool) -> DayKey? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let head = String(s.split(separator: " ").first ?? Substring(s))
        let parts = head.split(separator: "/")
        if parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), var y = Int(parts[2]) {
            if parts[2].count == 2 { y += y < 70 ? 2000 : 1900 }
            let (m, d) = monthFirst ? (a, b) : (b, a)
            guard (1...12).contains(m), (1...31).contains(d), y > 1900 else { return nil }
            return DayKey(year: y, month: m, day: d)
        }
        return day(s)
    }

    public static func day(_ raw: String?) -> DayKey? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // "2021-03-15T10:22:00Z" and "2021-03-15 10:22"
        if s.count >= 10, s.prefix(4).allSatisfy(\.isNumber), s.dropFirst(4).first == "-" { s = String(s.prefix(10)) }
        // Spreadsheet serial day (e.g. 44270 = 15.03.2021) when a date column arrives as a plain number.
        if s.allSatisfy(\.isNumber), s.count == 5, let n = Int(s), (20_000...80_000).contains(n) {
            return DayKey(year: 1899, month: 12, day: 30).adding(days: n)
        }
        let head = String(s.split(separator: " ").first ?? Substring(s))
        if let d = DayKey(iso: head), d.year > 1900 { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .utc
        f.isLenient = false
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let date = f.date(from: head) {
                let d = DayKey(date: date, timeZone: .utc)
                if d.year > 1900 && d.year < 2200 { return d }
            }
        }
        for loc in ["de_DE", "en_US_POSIX"] {
            f.locale = Locale(identifier: loc)
            for fmt in wordFormats {
                f.dateFormat = fmt
                if let date = f.date(from: s) {
                    let d = DayKey(date: date, timeZone: .utc)
                    if d.year > 1900 && d.year < 2200 { return d }
                }
            }
        }
        return nil
    }

    public static func isISIN(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.count == 12 else { return false }
        let chars = Array(t)
        guard chars[0].isLetter, chars[1].isLetter, chars[11].isNumber else { return false }
        return chars.allSatisfy { $0.isLetter || $0.isNumber }
    }

    public static func isWKN(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        return t.count == 6 && t.allSatisfy { $0.isLetter || $0.isNumber } && t.contains(where: { $0.isNumber })
    }

    /// Normalized key for fuzzy name matching ("Cameco Corp." -> "cameco").
    public static func nameKey(_ name: String) -> String {
        let stop: Set<String> = ["inc", "corp", "corporation", "ltd", "limited", "plc", "se", "ag", "sa", "asa", "nv", "co", "company", "the", "group", "holding", "holdings", "shs", "reg", "registered", "class", "cl", "a", "b", "ord", "adr", "kgaa", "spa", "ab", "oyj", "as", "bhd", "tbk", "pcl", "et", "de"]
        // "S.p.A." and "Corp." lose their dots first so abbreviations stay one word.
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
            .replacingOccurrences(of: ".", with: "")
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 || $0.first?.isNumber == true }
        let kept = words.filter { !stop.contains($0) }
        return (kept.isEmpty ? words : kept).prefix(2).joined(separator: " ")
    }
}

public extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func num(_ key: String) -> Double? { Lenient.double(any: self[key]) }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func arr(_ key: String) -> [Any]? { self[key] as? [Any] }
}
