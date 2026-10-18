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

    private static let dateFormats = ["dd.MM.yyyy", "d.M.yyyy", "dd.MM.yy", "d.M.yy", "yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "yyyy/MM/dd", "dd-MM-yyyy"]

    public static func day(_ raw: String?) -> DayKey? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let head = String(s.split(separator: " ").first ?? Substring(s))
        if let d = DayKey(iso: head), d.year > 1900 { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .utc
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let date = f.date(from: head) {
                let d = DayKey(date: date, timeZone: .utc)
                if d.year > 1900 && d.year < 2200 { return d }
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
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
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
