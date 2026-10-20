import Foundation

/// Reads tables (CSV/TSV text, text copied from Excel/Numbers, Excel and OpenDocument files) and turns rows into position drafts.
public enum CSVImport {
    public struct Table: Sendable {
        public var headers: [String]
        public var rows: [[String]]
        /// Name of the sheet the table comes from (spreadsheets with several sheets).
        public var sheetName: String?
        /// True when the first row was data and the headers are made up ("Spalte 1" ...).
        public var syntheticHeaders: Bool

        public init(headers: [String], rows: [[String]], sheetName: String? = nil, syntheticHeaders: Bool = false) {
            self.headers = headers
            self.rows = rows
            self.sheetName = sheetName
            self.syntheticHeaders = syntheticHeaders
        }

        /// First non-empty values of a column, for the column picker.
        public func samples(_ column: Int, count: Int = 2) -> [String] {
            Array(rows.lazy.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }.prefix(count))
        }
    }

    public enum Field: String, CaseIterable, Codable, Sendable {
        case ignore, name, isin, wkn, ticker, exchange, quantity, pricePerUnit, totalCost, day, kind, bank, theme, currency, note

        public var label: String {
            switch self {
            case .ignore: return "Nicht verwenden"
            case .name: return "Name"
            case .isin: return "ISIN"
            case .wkn: return "WKN"
            case .ticker: return "Kürzel"
            case .exchange: return "Börse"
            case .quantity: return "Stück"
            case .pricePerUnit: return "Kaufkurs pro Stück"
            case .totalCost: return "Kaufwert gesamt"
            case .day: return "Kaufdatum"
            case .kind: return "Kauf/Verkauf"
            case .bank: return "Bank/Depot"
            case .theme: return "Thema"
            case .currency: return "Währung"
            case .note: return "Notiz"
            }
        }

        /// Header words in order of preference (lowercased, without accents and dots).
        var synonyms: [String] {
            switch self {
            case .ignore: return []
            case .name: return ["name", "bezeichnung", "wertpapier", "wertpapiername", "wertpapierbezeichnung", "gattungsbezeichnung", "gattung",
                                "titel", "instrument", "unternehmen", "aktie", "security", "description", "produkt", "firma", "basiswert"]
            case .isin: return ["isin"]
            case .wkn: return ["wkn", "wertpapierkennnummer"]
            case .ticker: return ["kurzel", "kuerzel", "borsenkurzel", "symbol", "ticker", "tickersymbol", "code"]
            case .exchange: return ["borse", "boerse", "handelsplatz", "borsenplatz", "handelsort", "exchange", "markt", "venue", "platz"]
            case .quantity: return ["stuck", "stueck", "stuckzahl", "anzahl", "menge", "bestand", "nominale", "nominal", "stk", "anteile",
                                    "quantity", "shares", "units", "qty"]
            case .pricePerUnit: return ["kaufkurs", "einstandskurs", "ausfuhrungskurs", "durchschnittskurs", "kaufpreis pro stuck", "preis pro stuck",
                                        "kaufpreis/stuck", "preis/stuck", "stuckpreis", "kurs bei kauf", "ek-kurs", "ek kurs", "einstandspreis",
                                        "kaufpreis", "buy price", "purchase price", "average price", "avg price", "cost per share"]
            case .totalCost: return ["kaufwert", "einstandswert", "anschaffungswert", "anschaffungskosten", "kaufbetrag", "einstand gesamt",
                                     "kaufpreis gesamt", "gesamtkosten", "investiert", "umsatz", "betrag", "cost basis", "cost", "amount", "total"]
            case .day: return ["kaufdatum", "kauftag", "erwerbsdatum", "anschaffungsdatum", "kauf am", "gekauft am", "geschaftstag", "handelstag",
                               "schlusstag", "ausfuhrungsdatum", "datum", "buchungstag", "valuta", "trade date", "purchase date", "date"]
            case .kind: return ["transaktionsart", "buchungsart", "geschaftsart", "transaktion", "vorgang", "typ", "art", "richtung",
                                "type", "transaction", "action", "side"]
            case .bank: return ["bank", "depotbank", "depot", "broker", "konto", "depotname", "kreditinstitut"]
            case .theme: return ["thema", "themen", "kategorie", "gruppe", "musterdepot", "sektor", "branche", "liste", "watchlist",
                                 "strategie", "segment", "sector", "category"]
            case .currency: return ["wahrung", "waehrung", "currency", "whg", "ccy"]
            case .note: return ["notiz", "notizen", "bemerkung", "kommentar", "anmerkung", "note", "notes"]
            }
        }

        /// Words that rule the field out, e.g. "Akt. Kurs" is the current price, not the purchase price.
        var excludes: [String] {
            switch self {
            case .pricePerUnit: return ["akt", "aktuell", "aktueller", "letzter", "schluss", "tages", "ziel", "stop", "limit", "hoch", "tief",
                                        "current", "last", "market", "markt", "wert", "gesamt", "total", "diff", "veranderung", "datum", "zeit"]
            case .totalCost: return ["kurswert", "marktwert", "aktuell", "aktueller", "akt", "tageswert", "depotwert", "gewinn", "verlust", "diff",
                                     "ertrag", "performance", "veranderung", "market", "current", "pro", "stuck", "datum"]
            case .day: return ["kurs", "stand", "update", "fallig", "verfall", "geburt"]
            case .quantity: return ["preis", "kurs", "wert", "price", "value"]
            case .name: return ["kenn", "nummer", "typ", "art", "kategorie", "kurz"]
            case .ticker: return ["wahrung", "currency", "isin", "land", "country", "post"]
            case .exchange: return ["wert", "kurs", "kurzel", "zeit", "kapital"]
            case .bank: return ["wert", "nummer", "nr", "anteil"]
            case .kind: return ["wertpapier", "asset", "order", "konto", "wahrung", "datum"]
            default: return []
            }
        }
    }

    /// One purchase (or the remainder of it after sales).
    public struct DraftLot: Hashable, Sendable {
        public var day: DayKey?
        public var quantity: Double
        /// Total paid in `currency`; nil when the file has no price.
        public var cost: Double?
        public var currency: String
        public var row: Int
    }

    public struct Draft: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var rows: [Int]
        public var name: String
        public var isin: String?
        public var wkn: String?
        public var ticker: String?
        public var exchangeText: String?
        public var exchangeID: ExchangeID?
        public var lots: [DraftLot]
        public var bank: String?
        public var theme: String?
        public var note: String
        /// Problems the user should look at.
        public var issues: [String]
        /// Plain information (merged rows, currency conversion).
        public var notes: [String]
        /// All shares were sold again.
        public var soldOut: Bool
        public var include: Bool

        public var identifier: String? { isin ?? wkn ?? ticker }
        public var quantity: Double? { lots.isEmpty ? nil : lots.reduce(0) { $0 + $1.quantity } }
        /// Total cost in the purchase currency, nil if any purchase has no price.
        public var totalCost: Double? {
            guard !lots.isEmpty, lots.allSatisfy({ $0.cost != nil }) else { return nil }
            return lots.reduce(0) { $0 + ($1.cost ?? 0) }
        }
        public var costCurrency: String { lots.first?.currency ?? "EUR" }
    }

    // MARK: Text to rows

    /// Splits CSV/TSV text into rows. Handles quotes, line breaks in quotes and the usual delimiters.
    public static func rows(_ text: String) -> [[String]] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let delim = detectDelimiter(Array(lines.prefix(40)))
        var rows: [[String]] = []
        var buffer = ""
        for line in lines {
            buffer += (buffer.isEmpty ? "" : "\n") + line
            if buffer.filter({ $0 == "\"" }).count % 2 == 1 { continue }
            rows.append(split(buffer, delim))
            buffer = ""
        }
        if !buffer.isEmpty { rows.append(split(buffer, delim)) }
        return rows
    }

    static func detectDelimiter(_ lines: [String]) -> Character {
        let options: [Character] = ["\t", ";", ",", "|"]
        var best: Character = ";"
        var bestScore = -1
        for d in options {
            let counts = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { split($0, d).count }
            guard let maxCount = counts.max(), maxCount > 1 else { continue }
            // The most common field count wins (bank exports have a few meta lines with other counts).
            var freq: [Int: Int] = [:]
            for c in counts where c > 1 { freq[c, default: 0] += 1 }
            let (mode, n) = freq.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value } ?? (0, 0)
            let score = n * 10 + mode
            if score > bestScore { bestScore = score; best = d }
        }
        return best
    }

    static func split(_ line: String, _ d: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted.toggle() }
            } else if c == d && !quoted {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        // Trailing delimiter ("a;b;") makes an empty last field.
        if out.count > 1, out.last == "" { out.removeLast() }
        return out
    }

    // MARK: Header

    /// Parses text and finds the header row.
    public static func parse(_ text: String) -> Table { table(rows: rows(text)) }

    /// Picks the sheet with the most recognisable table.
    public static func bestTable(_ sheets: [ImportFile.Sheet]) -> Table {
        let tables = sheets.map { table(rows: $0.rows, sheetName: $0.name) }
        return tables.max { score($0) < score($1) } ?? Table(headers: [], rows: [])
    }

    static func score(_ t: Table) -> Int {
        let fields = guessMapping(t.headers, rows: t.rows).filter { $0 != .ignore }.count
        return fields * 1000 + min(t.rows.count, 999)
    }

    public static func table(rows raw: [[String]], sheetName: String? = nil) -> Table {
        let rows = raw.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            .filter { !$0.allSatisfy(\.isEmpty) }
        guard !rows.isEmpty else { return Table(headers: [], rows: [], sheetName: sheetName) }
        let width = rows.map(\.count).max() ?? 0
        // Header = row with the most recognised column names among the first 30 rows (at least two).
        var headerIndex: Int?
        var bestHits = 1
        for (i, r) in rows.prefix(30).enumerated() {
            let hits = Set(r.map { guess($0) }.filter { $0 != .ignore }).count
            if hits > bestHits { bestHits = hits; headerIndex = i }
        }
        func pad(_ r: [String]) -> [String] { r.count < width ? r + Array(repeating: "", count: width - r.count) : r }
        if let h = headerIndex {
            let headers = pad(rows[h])
            let body = rows[(h + 1)...].map(pad).filter { $0 != headers }
            return Table(headers: headers, rows: Array(body), sheetName: sheetName)
        }
        // A single column name in the first row (e.g. just "ISIN") still counts as header.
        if rows[0].contains(where: isExactHeader) {
            return Table(headers: pad(rows[0]), rows: rows.dropFirst().map(pad), sheetName: sheetName)
        }
        // No header at all: every row is data.
        let headers = (0..<width).map { "Spalte \($0 + 1)" }
        return Table(headers: headers, rows: rows.map(pad), sheetName: sheetName, syntheticHeaders: true)
    }

    static func isExactHeader(_ s: String) -> Bool {
        let h = fold(s)
        return !h.isEmpty && Field.allCases.contains { $0.synonyms.contains(h) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "ø", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// How well a header names a field (0 = not at all).
    static func score(_ field: Field, header: String) -> Int {
        let h = fold(header)
        guard !h.isEmpty else { return 0 }
        let toks = tokens(h)
        for x in field.excludes where toks.contains(x) || (x.count >= 5 && h.contains(x)) { return 0 }
        var best = 0
        for (i, syn) in field.synonyms.enumerated() {
            let s: Int
            if h == syn {
                s = 300
            } else if toks.first == syn || h.hasPrefix(syn + " ") {
                s = 200
            } else if toks.contains(syn) || (syn.count >= 5 && h.contains(syn)) || (syn.contains(" ") && h.contains(syn)) {
                s = 100
            } else {
                continue
            }
            best = max(best, s - i)
        }
        return best
    }

    public static func guess(_ header: String) -> Field {
        var best: (Field, Int) = (.ignore, 0)
        for f in Field.allCases where f != .ignore {
            let s = score(f, header: header)
            if s > best.1 { best = (f, s) }
        }
        return best.0
    }

    /// One field per column, each field at most once; the best matches are assigned first.
    public static func guessMapping(_ headers: [String], rows: [[String]] = []) -> [Field] {
        var pairs: [(col: Int, field: Field, score: Int)] = []
        for (c, h) in headers.enumerated() {
            for f in Field.allCases where f != .ignore {
                let s = score(f, header: h)
                if s > 0 { pairs.append((c, f, s)) }
            }
        }
        pairs.sort { $0.score == $1.score ? $0.col < $1.col : $0.score > $1.score }
        var out = [Field](repeating: .ignore, count: headers.count)
        var used = Set<Field>()
        for p in pairs where out[p.col] == .ignore && !used.contains(p.field) {
            out[p.col] = p.field
            used.insert(p.field)
        }
        // Columns without a usable header: recognise ISINs, dates and names by their content.
        func column(_ c: Int) -> [String] { rows.compactMap { c < $0.count && !$0[c].isEmpty ? $0[c] : nil } }
        for c in headers.indices where out[c] == .ignore {
            let v = column(c)
            guard v.count >= 1 else { continue }
            let share = { (test: (String) -> Bool) -> Double in Double(v.filter(test).count) / Double(v.count) }
            if !used.contains(.isin), share(Lenient.isISIN) >= 0.6 {
                out[c] = .isin; used.insert(.isin)
            } else if !used.contains(.day), share({ Lenient.day($0) != nil && Lenient.double($0) == nil }) >= 0.6 {
                out[c] = .day; used.insert(.day)
            } else if !used.contains(.name), share({ s in s.count >= 3 && s.filter(\.isLetter).count * 2 > s.count && !Lenient.isISIN(s) }) >= 0.7 {
                out[c] = .name; used.insert(.name)
            }
        }
        return out
    }

    // MARK: Numbers

    /// Removes currency signs, units and spaces; keeps digits, separators and signs.
    static func cleanNumber(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var negative = false
        if t.hasPrefix("(") && t.hasSuffix(")") { negative = true; t = String(t.dropFirst().dropLast()) }
        if t.hasSuffix("-") && t.dropLast().contains(where: \.isNumber) { negative = true; t.removeLast() }
        t = t.replacingOccurrences(of: "\u{2212}", with: "-")
        var out = String(t.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" || $0 == "+" })
        if out.hasPrefix("+") { out.removeFirst() }
        if negative && !out.hasPrefix("-") { out = "-" + out }
        return out
    }

    enum Separator { case comma, dot }

    /// What a single value says about the decimal separator (nil = ambiguous).
    static func vote(_ raw: String) -> Separator? {
        let s = cleanNumber(raw).replacingOccurrences(of: "-", with: "")
        let commas = s.filter { $0 == "," }.count, dots = s.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            return s.lastIndex(of: ",")! > s.lastIndex(of: ".")! ? .comma : .dot
        }
        if commas == 1 {
            let tail = s.split(separator: ",", omittingEmptySubsequences: false).last ?? ""
            return tail.count == 3 && !s.hasPrefix("0,") ? nil : .comma
        }
        if commas > 1 { return .dot }
        if dots == 1 {
            let tail = s.split(separator: ".", omittingEmptySubsequences: false).last ?? ""
            return tail.count == 3 && !s.hasPrefix("0.") ? nil : .dot
        }
        if dots > 1 { return .comma }
        return nil
    }

    static func decimalSeparator(_ values: [String]) -> Separator? {
        var c = 0, d = 0
        for v in values {
            switch vote(v) {
            case .comma?: c += 1
            case .dot?: d += 1
            case nil: break
            }
        }
        if c == 0 && d == 0 { return nil }
        return c >= d ? .comma : .dot
    }

    static func number(_ raw: String, _ sep: Separator) -> Double? {
        let s = cleanNumber(raw)
        guard s.contains(where: \.isNumber) else { return nil }
        let t = sep == .comma ? s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                              : s.replacingOccurrences(of: ",", with: "")
        return Double(t)
    }

    // MARK: Currency

    static let currencyCodes: Set<String> = ["EUR", "USD", "GBP", "GBX", "GBp", "CHF", "JPY", "CAD", "AUD", "NOK", "SEK", "DKK", "HKD",
                                             "SGD", "NZD", "PLN", "CZK", "HUF", "ZAR", "CNY", "INR", "BRL", "MXN", "ILS", "TRY", "KRW", "USDT"]

    /// Currency named in a header or a cell ("Kaufkurs in USD", "12,50 $", "Einstandswert (EUR)").
    static func currencyHint(_ s: String) -> String? {
        let upper = s.uppercased()
        for t in tokens(upper) where currencyCodes.contains(t) { return t == "GBX" ? "GBp" : t }
        if s.contains("€") { return "EUR" }
        if s.contains("$") { return "USD" }
        if s.contains("£") { return "GBP" }
        if s.contains("¥") { return "JPY" }
        return nil
    }

    // MARK: Drafts

    enum RowKind { case buy, sell, skip }

    static func kind(_ s: String?) -> RowKind {
        guard let s, !s.isEmpty else { return .buy }
        let f = fold(s)
        let skip = ["dividend", "ertrag", "zins", "ausschuttung", "coupon", "kupon", "steuer", "gebuhr", "fee", "tax", "interest",
                    "storno", "kapitalmassnahme", "einzahlung", "auszahlung", "deposit", "withdraw"]
        if skip.contains(where: { f.contains($0) }) { return .skip }
        let sell = ["verkauf", "sell", "sale", "abgang", "auslieferung", "ausbuchung", "entnahme", "vk"]
        if sell.contains(where: { f == $0 || f.contains($0) }) && !f.contains("ankauf") { return .sell }
        return .buy
    }

    public static func drafts(_ table: Table, mapping: [Field], catalog: ExchangeCatalog) -> [Draft] {
        func col(_ f: Field) -> Int? { mapping.firstIndex(of: f) }
        func values(_ f: Field) -> [String] {
            guard let c = col(f) else { return [] }
            return table.rows.compactMap { c < $0.count ? $0[c] : nil }.filter { !$0.isEmpty }
        }
        // Decimal separator per column; ambiguous columns follow the rest of the table, then German usage.
        let numericFields: [Field] = [.quantity, .pricePerUnit, .totalCost]
        let tableSep = decimalSeparator(numericFields.flatMap(values)) ?? .comma
        var sep: [Field: Separator] = [:]
        for f in numericFields { sep[f] = decimalSeparator(values(f)) ?? tableSep }
        let quantityAmbiguous = decimalSeparator(values(.quantity)) == nil
        // 04/03/2024: US files put the month first. A value like 03/15/2021 settles it for the whole column.
        let slashDates = values(.day).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            .map { $0.split(separator: "/").compactMap { Int($0) } }.filter { $0.count == 3 }
        let monthFirst = slashDates.contains { $0[1] > 12 } && !slashDates.contains { $0[0] > 12 }
        let headerCurrency: [Field: String] = Dictionary(uniqueKeysWithValues: [Field.pricePerUnit, .totalCost].compactMap { f in
            col(f).flatMap { table.headers[$0] }.flatMap(currencyHint).map { (f, $0) }
        })

        struct Row {
            var index: Int
            var name: String
            var isin, wkn, ticker, exchange, bank, theme, note: String?
            var issues: [String]
            var day: DayKey?
            var quantity: Double?
            var cost: Double?
            var currency: String
            var kind: RowKind
        }

        var parsed: [Row] = []
        for (ri, r) in table.rows.enumerated() {
            func val(_ f: Field) -> String? {
                guard let i = col(f), i < r.count else { return nil }
                let v = r[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            var row = Row(index: ri + 1, name: val(.name) ?? "", ticker: val(.ticker), exchange: val(.exchange), bank: val(.bank),
                          theme: val(.theme), note: val(.note), issues: [], currency: "EUR", kind: kind(val(.kind)))
            if row.kind == .skip { continue }
            if let i = val(.isin) {
                if Lenient.isISIN(i) { row.isin = i.uppercased() } else { row.issues.append("ISIN \u{201E}\(i)\u{201C} ungültig") }
            }
            if let w = val(.wkn), Lenient.isWKN(w) { row.wkn = w.uppercased() }
            // Some exports put the ISIN into the name or ticker column.
            if row.isin == nil, let t = row.ticker, Lenient.isISIN(t) { row.isin = t.uppercased(); row.ticker = nil }
            if row.isin == nil, Lenient.isISIN(row.name) { row.isin = row.name.uppercased(); row.name = "" }
            if row.wkn == nil, let t = row.ticker, Lenient.isWKN(t), t.allSatisfy(\.isNumber) { row.wkn = t; row.ticker = nil }
            // Summary lines ("Summe", "Gesamt") are not securities.
            let lowered = fold(row.name)
            if row.isin == nil && row.wkn == nil && row.ticker == nil,
               ["summe", "gesamt", "total", "depotwert", "saldo", "zwischensumme"].contains(where: { lowered.hasPrefix($0) }) || row.name.isEmpty {
                continue
            }
            if let q = val(.quantity) {
                var v = number(q, sep[.quantity] ?? tableSep)
                // "12.145" alone is ambiguous; price times quantity decides when both are known.
                if quantityAmbiguous, let unit = val(.pricePerUnit).flatMap({ number($0, sep[.pricePerUnit] ?? tableSep) }),
                   let total = val(.totalCost).flatMap({ number($0, sep[.totalCost] ?? tableSep) }), unit > 0, total != 0 {
                    let alt = number(q, (sep[.quantity] ?? tableSep) == .comma ? .dot : .comma)
                    if let a = alt, let cur = v, abs(abs(a) * unit - abs(total)) < abs(abs(cur) * unit - abs(total)) { v = a }
                }
                row.quantity = v
                if v == nil { row.issues.append("Stückzahl \u{201E}\(q)\u{201C} unlesbar") }
            }
            if row.kind == .buy, let q = row.quantity, q < 0 { row.kind = .sell }
            if let q = row.quantity { row.quantity = abs(q) }
            let rowCurrency = val(.currency).flatMap(currencyHint) ?? val(.currency).map { $0.uppercased() }
            if let t = val(.totalCost), let v = number(t, sep[.totalCost] ?? tableSep), v != 0 {
                row.cost = abs(v)
                row.currency = headerCurrency[.totalCost] ?? currencyHint(t) ?? rowCurrency ?? "EUR"
            } else if let u = val(.pricePerUnit), let v = number(u, sep[.pricePerUnit] ?? tableSep), v != 0, let q = row.quantity {
                row.cost = abs(v) * q
                row.currency = headerCurrency[.pricePerUnit] ?? currencyHint(u) ?? rowCurrency ?? "EUR"
            }
            if row.currency == "GBX" { row.currency = "GBp" }
            if row.currency == "GBp", let c = row.cost { row.cost = c / 100; row.currency = "GBP" }
            if let s = val(.day) {
                if let d = Lenient.day(s, monthFirst: monthFirst) { row.day = d } else { row.issues.append("Datum \u{201E}\(s)\u{201C} unlesbar") }
            }
            parsed.append(row)
        }

        // Rows of the same security (and bank) become one position with several purchases.
        func key(_ r: Row) -> String {
            let id = r.isin ?? r.wkn ?? r.ticker.map { "\($0)|\(r.exchange ?? "")" } ?? "name:" + Lenient.nameKey(r.name)
            return id + "|" + fold(r.bank ?? "")
        }
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for r in parsed {
            let k = key(r)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(r)
        }

        var out: [Draft] = []
        for k in order {
            let rs = groups[k]!
            func firstValue(_ get: (Row) -> String?) -> String? { rs.lazy.compactMap(get).first }
            var d = Draft(rows: rs.map(\.index), name: rs.lazy.map(\.name).first { !$0.isEmpty } ?? "",
                          isin: firstValue(\.isin), wkn: firstValue(\.wkn), ticker: firstValue(\.ticker),
                          exchangeText: firstValue(\.exchange), exchangeID: nil, lots: [], bank: firstValue(\.bank),
                          theme: firstValue(\.theme), note: rs.compactMap(\.note).joined(separator: " "),
                          issues: Array(Set(rs.flatMap(\.issues))).sorted(), notes: [], soldOut: false, include: true)
            if d.name.isEmpty { d.name = d.identifier ?? "" }
            if let ex = d.exchangeText {
                if let e = catalog.matchName(ex) { d.exchangeID = e.id } else { d.issues.append("Börse \u{201E}\(ex)\u{201C} unbekannt, Standardbörse wird genommen") }
            }
            // Purchases in date order; sales take shares away from the oldest purchases first.
            let sorted = rs.enumerated().sorted { a, b in
                switch (a.element.day, b.element.day) {
                case let (x?, y?) where x != y: return x < y
                default: return a.offset < b.offset
                }
            }.map(\.element)
            var lots: [DraftLot] = []
            var sold = false
            for r in sorted {
                guard let q = r.quantity, q > 0 else { continue }
                if r.kind == .sell {
                    sold = true
                    var rest = q
                    var i = 0
                    while rest > 1e-9 && i < lots.count {
                        let take = min(rest, lots[i].quantity)
                        let share = take / lots[i].quantity
                        lots[i].cost = lots[i].cost.map { $0 * (1 - share) }
                        lots[i].quantity -= take
                        rest -= take
                        i += 1
                    }
                    lots.removeAll { $0.quantity <= 1e-9 }
                } else {
                    lots.append(DraftLot(day: r.day, quantity: q, cost: r.cost, currency: r.currency, row: r.index))
                }
            }
            d.lots = lots
            if rs.count > 1 { d.notes.append("aus \(rs.count) Zeilen zusammengefasst") }
            if sold && lots.isEmpty {
                d.soldOut = true
                d.include = false
                d.notes.append("komplett verkauft")
            }
            if d.identifier == nil { d.notes.append("ohne ISIN, wird über den Namen gesucht") }
            if !lots.isEmpty {
                if lots.contains(where: { $0.cost == nil }) { d.issues.append("Kaufpreis fehlt, Seit-Kauf-Werte bleiben leer") }
                if lots.contains(where: { $0.day == nil }) { d.notes.append("Kaufdatum fehlt, heute eingetragen") }
                let foreign = Set(lots.filter { $0.cost != nil && $0.currency != "EUR" }.map(\.currency))
                if !foreign.isEmpty {
                    d.notes.append("Kaufpreis in \(foreign.sorted().joined(separator: ", ")), wird zum EZB-Kurs vom Kaufdatum in Euro umgerechnet")
                }
            }
            out.append(d)
        }
        return out
    }
}
