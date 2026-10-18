import Foundation

/// Reads CSV/TSV text (files or text copied from Excel/Numbers) and turns rows into position drafts.
public enum CSVImport {
    public struct Table: Sendable {
        public var headers: [String]
        public var rows: [[String]]
        public var delimiter: Character
    }

    public enum Field: String, CaseIterable, Codable, Sendable {
        case ignore, name, isin, wkn, ticker, exchange, quantity, pricePerUnit, totalCost, day, bank, theme, currency, note

        public var label: String {
            switch self {
            case .ignore: return "Nicht verwenden"
            case .name: return "Name"
            case .isin: return "ISIN"
            case .wkn: return "WKN"
            case .ticker: return "Kürzel"
            case .exchange: return "Börse"
            case .quantity: return "Stück"
            case .pricePerUnit: return "Kaufkurs pro Stück (EUR)"
            case .totalCost: return "Kaufwert gesamt (EUR)"
            case .day: return "Kaufdatum"
            case .bank: return "Bank/Depot"
            case .theme: return "Thema"
            case .currency: return "Währung"
            case .note: return "Notiz"
            }
        }

        /// Header words that identify the column (lowercased, without accents).
        var synonyms: [String] {
            switch self {
            case .ignore: return []
            case .name: return ["name", "bezeichnung", "wertpapier", "titel", "instrument", "wertpapiername", "unternehmen", "aktie", "security"]
            case .isin: return ["isin"]
            case .wkn: return ["wkn", "wertpapierkennnummer"]
            case .ticker: return ["kurzel", "kuerzel", "symbol", "ticker", "code"]
            case .exchange: return ["borse", "boerse", "handelsplatz", "platz", "exchange", "markt", "handelsort"]
            case .quantity: return ["stuck", "stueck", "anzahl", "menge", "bestand", "nominale", "stuckzahl", "quantity", "shares", "stk"]
            case .pricePerUnit: return ["kaufkurs", "einstandskurs", "kaufpreis/stuck", "kaufpreis pro stuck", "kurs bei kauf", "einstand", "buy price", "purchase price", "einstandspreis"]
            case .totalCost: return ["kaufwert", "einstandswert", "kaufpreis gesamt", "anschaffungswert", "kaufbetrag", "investiert", "cost", "gesamtkosten", "einstand gesamt"]
            case .day: return ["kaufdatum", "datum", "erwerbsdatum", "kauf am", "date", "gekauft am"]
            case .bank: return ["bank", "depot", "depotbank", "broker", "konto"]
            case .theme: return ["thema", "kategorie", "gruppe", "musterdepot", "sektor", "branche", "liste"]
            case .currency: return ["wahrung", "waehrung", "currency", "whg"]
            case .note: return ["notiz", "bemerkung", "kommentar", "note"]
            }
        }
    }

    public struct Draft: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var row: Int
        public var name: String
        public var isin: String?
        public var wkn: String?
        public var ticker: String?
        public var exchangeText: String?
        public var exchangeID: ExchangeID?
        public var quantity: Double?
        public var totalCostEUR: Double?
        public var day: DayKey?
        public var bank: String?
        public var theme: String?
        public var note: String
        public var issues: [String]

        public var identifier: String? { isin ?? wkn ?? ticker }
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> Table {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Skip leading lines that are clearly not the header (bank exports often start with meta data).
        let candidates = lines.prefix(15)
        let delim = detectDelimiter(Array(candidates))
        var rows: [[String]] = []
        var buffer = ""
        var inQuotes = false
        for line in lines {
            buffer += (buffer.isEmpty ? "" : "\n") + line
            inQuotes = buffer.filter { $0 == "\"" }.count % 2 == 1
            if inQuotes { continue }
            let fields = split(buffer, delim)
            buffer = ""
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            rows.append(fields)
        }
        guard !rows.isEmpty else { return Table(headers: [], rows: [], delimiter: delim) }
        // Header = first row with at least two recognised column names, else the first row.
        var headerIndex = 0
        for (i, r) in rows.prefix(15).enumerated() {
            let hits = r.filter { guess($0) != .ignore }.count
            if hits >= 2 { headerIndex = i; break }
        }
        let headers = rows[headerIndex].map { $0.trimmingCharacters(in: .whitespaces) }
        let body = Array(rows[(headerIndex + 1)...]).map { r -> [String] in
            var x = r
            if x.count < headers.count { x += Array(repeating: "", count: headers.count - x.count) }
            return x
        }
        return Table(headers: headers, rows: body, delimiter: delim)
    }

    static func detectDelimiter(_ lines: [String]) -> Character {
        let options: [Character] = ["\t", ";", ",", "|"]
        var best: Character = ";"
        var bestScore = -1
        for d in options {
            let counts = lines.filter { !$0.isEmpty }.map { split($0, d).count }
            guard let maxCount = counts.max(), maxCount > 1 else { continue }
            let consistent = counts.filter { $0 == maxCount }.count
            let score = consistent * 10 + maxCount
            if score > bestScore { bestScore = score; best = d }
        }
        return best
    }

    static func split(_ line: String, _ d: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == d && !quoted {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        chars.removeAll()
        return out
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
            .replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
    }

    public static func guess(_ header: String) -> Field {
        let h = fold(header)
        guard !h.isEmpty else { return .ignore }
        // Exact matches first, then "contains", most specific fields first.
        let order: [Field] = [.isin, .wkn, .totalCost, .pricePerUnit, .day, .quantity, .exchange, .currency, .ticker, .bank, .theme, .note, .name]
        for f in order where f.synonyms.contains(h) { return f }
        for f in order where f.synonyms.contains(where: { h.contains($0) }) { return f }
        return .ignore
    }

    public static func guessMapping(_ headers: [String]) -> [Field] {
        var used = Set<Field>()
        return headers.map { h in
            let g = guess(h)
            if g != .ignore && used.contains(g) { return .ignore }
            used.insert(g)
            return g
        }
    }

    /// Decimal comma or point? Looks at all numeric cells of the mapped number columns.
    static func prefersDecimalComma(_ table: Table, _ mapping: [Field]) -> Bool {
        var comma = 0, dot = 0
        for r in table.rows {
            for (i, f) in mapping.enumerated() where [.quantity, .pricePerUnit, .totalCost].contains(f) && i < r.count {
                let v = r[i]
                if let lc = v.lastIndex(of: ","), v.distance(from: lc, to: v.endIndex) != 4 { comma += 1 }
                if let ld = v.lastIndex(of: "."), v.distance(from: ld, to: v.endIndex) != 4 { dot += 1 }
            }
        }
        return comma >= dot
    }

    static func number(_ s: String, decimalComma: Bool) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if decimalComma, !t.contains(","), t.contains(".") {
            // "1.234" in a German file means one thousand two hundred thirty-four.
            let groups = t.split(separator: ".")
            if groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 }) {
                return Lenient.double(t.replacingOccurrences(of: ".", with: ""))
            }
        }
        return Lenient.double(t)
    }

    public static func drafts(_ table: Table, mapping: [Field], catalog: ExchangeCatalog) -> [Draft] {
        let dc = prefersDecimalComma(table, mapping)
        var out: [Draft] = []
        for (ri, r) in table.rows.enumerated() {
            func val(_ f: Field) -> String? {
                guard let i = mapping.firstIndex(of: f), i < r.count else { return nil }
                let v = r[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            var d = Draft(row: ri + 1, name: val(.name) ?? "", isin: nil, wkn: nil, ticker: val(.ticker), exchangeText: val(.exchange),
                          exchangeID: nil, quantity: nil, totalCostEUR: nil, day: nil, bank: val(.bank), theme: val(.theme),
                          note: val(.note) ?? "", issues: [])
            if let i = val(.isin) {
                if Lenient.isISIN(i) { d.isin = i.uppercased() } else { d.issues.append("ISIN \u{201E}\(i)\u{201C} ungültig") }
            }
            if let w = val(.wkn), Lenient.isWKN(w) { d.wkn = w.uppercased() }
            // Some exports put the ISIN in the name column or the ticker column.
            if d.isin == nil, let t = d.ticker, Lenient.isISIN(t) { d.isin = t.uppercased(); d.ticker = nil }
            if let ex = d.exchangeText {
                if let e = catalog.matchName(ex) { d.exchangeID = e.id } else { d.issues.append("Börse \u{201E}\(ex)\u{201C} unbekannt") }
            }
            if let q = val(.quantity) { d.quantity = number(q, decimalComma: dc) }
            let total = val(.totalCost).flatMap { number($0, decimalComma: dc) }
            let unit = val(.pricePerUnit).flatMap { number($0, decimalComma: dc) }
            if let t = total { d.totalCostEUR = abs(t) } else if let u = unit, let q = d.quantity { d.totalCostEUR = abs(u * q) }
            if let s = val(.day) {
                if let day = Lenient.day(s) { d.day = day } else { d.issues.append("Datum \u{201E}\(s)\u{201C} unlesbar") }
            }
            if let c = val(.currency), c.uppercased() != "EUR", c != "€" {
                d.issues.append("Kaufwert in \(c), bitte in EUR prüfen")
            }
            if d.name.isEmpty && d.identifier == nil { continue }
            if d.name.isEmpty { d.name = d.identifier ?? "" }
            if d.identifier == nil { d.issues.append("Weder ISIN noch WKN noch Kürzel") }
            if d.quantity != nil && d.totalCostEUR == nil { d.issues.append("Kaufpreis fehlt") }
            out.append(d)
        }
        return out
    }
}
