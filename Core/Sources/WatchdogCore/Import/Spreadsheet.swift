import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Turns any file a user might pick (CSV, TXT, Excel, OpenDocument) into rows of text cells.
/// Numbers from spreadsheet cells are written with a decimal comma ("12,145"), dates as "dd.MM.yyyy",
/// so the importer reads them exactly like a German CSV file.
public enum ImportFile {
    public enum ReadError: Error, LocalizedError {
        case numbers, legacyExcel, empty, unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .numbers:
                return "Numbers-Dateien kann Watchdog nicht direkt lesen. In Numbers die Tabelle markieren, kopieren und hier einfügen, oder über Ablage > Exportieren > Excel speichern."
            case .legacyExcel:
                return "Das ist eine alte Excel-Datei (.xls). Bitte in Excel über Datei > Speichern unter als Excel-Arbeitsmappe (.xlsx) oder CSV speichern."
            case .empty:
                return "Die Datei enthält keine Tabelle."
            case .unreadable(let s):
                return "Die Datei ließ sich nicht lesen: \(s)"
            }
        }
    }

    public struct Sheet: Sendable {
        public var name: String
        public var rows: [[String]]
        public init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    /// All sheets of the file (one for text files).
    public static func sheets(data: Data, filename: String) throws -> [Sheet] {
        let ext = (filename as NSString).pathExtension.lowercased()
        let head = [UInt8](data.prefix(8))
        if ext == "numbers" { throw ReadError.numbers }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw ReadError.legacyExcel }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let zip: ZipArchive
            do { zip = try ZipArchive(data: data) } catch { throw ReadError.unreadable(error.localizedDescription) }
            if zip.entries["xl/workbook.xml"] != nil { return try XLSXReader.sheets(zip) }
            if zip.entries["content.xml"] != nil { return try ODSReader.sheets(zip) }
            if zip.entries.keys.contains(where: { $0.hasPrefix("Index/") }) { throw ReadError.numbers }
            throw ReadError.unreadable("unbekanntes Archiv")
        }
        let text = decodeText(data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadError.empty }
        return [Sheet(name: (filename as NSString).lastPathComponent, rows: CSVImport.rows(text))]
    }

    /// Text files come from many programs: UTF-8 (with or without BOM), UTF-16 ("Unicode-Text" from Excel),
    /// Windows-1252 (Excel on Windows, many banks) and Mac Roman (older Excel for Mac).
    public static func decodeText(_ data: Data) -> String {
        let b = [UInt8](data)
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: b.dropFirst(3), as: UTF8.self) }
        if b.starts(with: [0xFF, 0xFE]) { return String(data: Data(b.dropFirst(2)), encoding: .utf16LittleEndian) ?? "" }
        if b.starts(with: [0xFE, 0xFF]) { return String(data: Data(b.dropFirst(2)), encoding: .utf16BigEndian) ?? "" }
        // UTF-16 without BOM: every second byte is zero for Latin text.
        let sample = b.prefix(400)
        if sample.count >= 4 {
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let half = sample.count / 2
            if oddZeros > half * 6 / 10 { return String(data: data, encoding: .utf16LittleEndian) ?? "" }
            if evenZeros > half * 6 / 10 { return String(data: data, encoding: .utf16BigEndian) ?? "" }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Windows-1252 or Mac Roman? Count typical German letters in both code pages.
        let win: Set<UInt8> = [0xE4, 0xF6, 0xFC, 0xC4, 0xD6, 0xDC, 0xDF, 0x80]
        let mac: Set<UInt8> = [0x8A, 0x9A, 0x9F, 0x80, 0x85, 0x86, 0xA7, 0xDB]
        let w = b.filter { win.contains($0) }.count
        let m = b.filter { mac.contains($0) }.count
        return CodePages.decode(b, table: m > w ? CodePages.macRoman : CodePages.windows1252)
    }

    /// German representation of a spreadsheet number: decimal comma, no grouping, no exponent.
    static func numberText(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.10f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    /// Spreadsheet serial day (days since 30.12.1899, or since 1.1.1904) as "dd.MM.yyyy".
    static func dateText(serial: Double, date1904: Bool) -> String {
        let base = date1904 ? DayKey(year: 1904, month: 1, day: 1) : DayKey(year: 1899, month: 12, day: 30)
        let d = base.adding(days: Int(serial.rounded(.down)))
        return Format.day(d)
    }
}

/// Collects elements of an XML document with a tiny callback interface.
final class XMLScan: NSObject, XMLParserDelegate {
    var onStart: (String, [String: String]) -> Void = { _, _ in }
    var onEnd: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }
    /// Report element names without their prefix ("x:row" becomes "row").
    var local = false

    static func run(_ data: Data, local: Bool = false, start: @escaping (String, [String: String]) -> Void,
                    end: @escaping (String) -> Void = { _ in }, text: @escaping (String) -> Void = { _ in }) throws {
        let s = XMLScan()
        s.local = local
        s.onStart = start
        s.onEnd = end
        s.onText = text
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.delegate = s
        if !p.parse() {
            throw ImportFile.ReadError.unreadable(p.parserError?.localizedDescription ?? "XML")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        onStart(name(elementName), attributeDict)
    }

    private func name(_ n: String) -> String {
        guard local, let i = n.lastIndex(of: ":") else { return n }
        return String(n[n.index(after: i)...])
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        onEnd(name(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        onText(string)
    }
}

/// Excel workbooks (.xlsx, .xlsm).
enum XLSXReader {
    static func sheets(_ zip: ZipArchive) throws -> [ImportFile.Sheet] {
        guard let wb = try zip.data("xl/workbook.xml") else { throw ImportFile.ReadError.empty }
        var sheetRefs: [(name: String, rid: String)] = []
        var date1904 = false
        try XMLScan.run(wb, local: true, start: { el, a in
            if el == "sheet", let n = a["name"], let r = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value {
                sheetRefs.append((n, r))
            }
            if el == "workbookPr", let v = a["date1904"], v == "1" || v.lowercased() == "true" { date1904 = true }
        })
        var targets: [String: String] = [:]
        if let rels = try zip.data("xl/_rels/workbook.xml.rels") {
            try XMLScan.run(rels, local: true, start: { el, a in
                if el == "Relationship", let id = a["Id"], let t = a["Target"] { targets[id] = t }
            })
        }
        let shared = try sharedStrings(zip)
        let dateStyles = try self.dateStyles(zip)

        var out: [ImportFile.Sheet] = []
        for (i, ref) in sheetRefs.enumerated() {
            var path = targets[ref.rid] ?? "worksheets/sheet\(i + 1).xml"
            if path.hasPrefix("/") { path.removeFirst() } else { path = "xl/" + path }
            guard let xml = try zip.data(path) else { continue }
            out.append(ImportFile.Sheet(name: ref.name, rows: try rows(xml, shared: shared, dateStyles: dateStyles, date1904: date1904)))
        }
        if out.isEmpty { throw ImportFile.ReadError.empty }
        return out
    }

    static func sharedStrings(_ zip: ZipArchive) throws -> [String] {
        guard let d = try zip.data("xl/sharedStrings.xml") else { return [] }
        var list: [String] = []
        var cur = ""
        var inT = false
        var inPhonetic = false
        try XMLScan.run(d, local: true, start: { el, _ in
            if el == "si" { cur = "" }
            if el == "rPh" { inPhonetic = true }
            if el == "t" { inT = true }
        }, end: { el in
            if el == "t" { inT = false }
            if el == "rPh" { inPhonetic = false }
            if el == "si" { list.append(cur) }
        }, text: { s in
            if inT && !inPhonetic { cur += s }
        })
        return list
    }

    /// Style indexes whose number format shows a date.
    static func dateStyles(_ zip: ZipArchive) throws -> Set<Int> {
        guard let d = try zip.data("xl/styles.xml") else { return [] }
        var customDate: Set<Int> = []
        var xfFormats: [Int] = []
        var inCellXfs = false
        try XMLScan.run(d, local: true, start: { el, a in
            if el == "numFmt", let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] {
                if isDateFormat(code) { customDate.insert(id) }
            }
            if el == "cellXfs" { inCellXfs = true }
            if inCellXfs && el == "xf" { xfFormats.append(a["numFmtId"].flatMap(Int.init) ?? 0) }
        }, end: { el in
            if el == "cellXfs" { inCellXfs = false }
        })
        let builtin: Set<Int> = Set(14...22).union([27, 30, 36, 45, 46, 47, 50, 57])
        var out: Set<Int> = []
        for (i, f) in xfFormats.enumerated() where builtin.contains(f) || customDate.contains(f) { out.insert(i) }
        return out
    }

    static func isDateFormat(_ code: String) -> Bool {
        // Drop quoted text, escapes and colour/condition brackets, then look for day/month/year tokens.
        var s = ""
        var quoted = false
        var bracket = false
        var skip = false
        for ch in code {
            if skip { skip = false; continue }
            if ch == "\\" { skip = true; continue }
            if ch == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if ch == "[" { bracket = true; continue }
            if ch == "]" { bracket = false; continue }
            if bracket { continue }
            s.append(ch)
        }
        let l = s.lowercased()
        return (l.contains("d") || l.contains("y") || l.contains("j") || l.contains("t")) && l.contains("m") && !l.contains("0") && !l.contains("#")
    }

    static func column(_ ref: String) -> Int? {
        var n = 0
        var any = false
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
            any = true
        }
        return any ? n - 1 : nil
    }

    static func rows(_ xml: Data, shared: [String], dateStyles: Set<Int>, date1904: Bool) throws -> [[String]] {
        var rows: [Int: [Int: String]] = [:]
        var rowIndex = -1
        var colIndex = 0
        var type = ""
        var style = 0
        var value = ""
        var inV = false
        var inInline = false
        try XMLScan.run(xml, local: true, start: { el, a in
            switch el {
            case "row":
                rowIndex = (a["r"].flatMap(Int.init) ?? (rowIndex + 2)) - 1
                colIndex = 0
            case "c":
                if let r = a["r"], let c = column(r) { colIndex = c }
                type = a["t"] ?? "n"
                style = a["s"].flatMap(Int.init) ?? 0
                value = ""
            case "v":
                inV = true
            case "is":
                inInline = true
            default: break
            }
        }, end: { el in
            switch el {
            case "v": inV = false
            case "is": inInline = false
            case "c":
                var text = value
                switch type {
                case "s": text = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "b": text = value == "1" ? "WAHR" : "FALSCH"
                case "e": text = ""
                case "str", "inlineStr": break
                default:
                    if let v = Double(value.trimmingCharacters(in: .whitespaces)) {
                        text = dateStyles.contains(style) ? ImportFile.dateText(serial: v, date1904: date1904) : ImportFile.numberText(v)
                    }
                }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, rowIndex >= 0 { rows[rowIndex, default: [:]][colIndex] = t }
                colIndex += 1
            default: break
            }
        }, text: { s in
            if inV || inInline { value += s }
        })
        return dense(rows)
    }

    static func dense(_ rows: [Int: [Int: String]]) -> [[String]] {
        guard let maxRow = rows.keys.max() else { return [] }
        let maxCol = rows.values.compactMap { $0.keys.max() }.max() ?? 0
        var out: [[String]] = []
        for r in 0...maxRow {
            guard let cells = rows[r] else { out.append([]); continue }
            out.append((0...maxCol).map { cells[$0] ?? "" })
        }
        return out
    }
}

/// OpenDocument spreadsheets (.ods from LibreOffice, also what Numbers can export).
enum ODSReader {
    static func sheets(_ zip: ZipArchive) throws -> [ImportFile.Sheet] {
        guard let d = try zip.data("content.xml") else { throw ImportFile.ReadError.empty }
        var sheets: [ImportFile.Sheet] = []
        var name = ""
        var rows: [[String]] = []
        var row: [String] = []
        var rowRepeat = 1
        var cellRepeat = 1
        var cellValue: String?
        var cellText = ""
        var inP = false
        var paragraphs = 0
        try XMLScan.run(d, start: { el, a in
            switch el {
            case "table:table":
                name = a["table:name"] ?? "Tabelle \(sheets.count + 1)"
                rows = []
            case "table:table-row":
                row = []
                rowRepeat = min(a["table:number-rows-repeated"].flatMap(Int.init) ?? 1, 10_000)
            case "table:table-cell", "table:covered-table-cell":
                cellRepeat = a["table:number-columns-repeated"].flatMap(Int.init) ?? 1
                cellText = ""
                paragraphs = 0
                switch a["office:value-type"] {
                case "float", "currency", "percentage":
                    cellValue = a["office:value"].flatMap(Double.init).map(ImportFile.numberText)
                case "date":
                    cellValue = a["office:date-value"].flatMap { Lenient.day($0) }.map { Format.day($0) }
                default:
                    cellValue = nil
                }
            case "text:p":
                if paragraphs > 0 { cellText += " " }
                paragraphs += 1
                inP = true
            case "text:s":
                if inP { cellText += String(repeating: " ", count: a["text:c"].flatMap(Int.init) ?? 1) }
            default: break
            }
        }, end: { el in
            switch el {
            case "text:p": inP = false
            case "table:table-cell", "table:covered-table-cell":
                let v = (cellValue ?? cellText).trimmingCharacters(in: .whitespacesAndNewlines)
                // Trailing empty cells are often repeated thousands of times; keep only what matters.
                let n = v.isEmpty ? min(cellRepeat, 64) : min(cellRepeat, 1_000)
                row.append(contentsOf: Array(repeating: v, count: n))
            case "table:table-row":
                while row.last?.isEmpty == true { row.removeLast() }
                if row.isEmpty {
                    rows.append(contentsOf: Array(repeating: [], count: min(rowRepeat, 50)))
                } else {
                    rows.append(contentsOf: Array(repeating: row, count: rowRepeat))
                }
            case "table:table":
                while rows.last?.isEmpty == true { rows.removeLast() }
                sheets.append(ImportFile.Sheet(name: name, rows: rows))
            default: break
            }
        }, text: { s in
            if inP { cellText += s }
        })
        if sheets.isEmpty { throw ImportFile.ReadError.empty }
        return sheets
    }
}
