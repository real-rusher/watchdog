import Foundation

/// Minimal ZIP reader (stored and deflate entries), enough for .xlsx and .ods files.
/// Pure Swift so it works the same on macOS, iOS and Linux without helper programs.
public struct ZipArchive {
    public struct Entry {
        public var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    public enum ZipError: Error, LocalizedError {
        case notZip, damaged(String), unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .notZip: return "Die Datei ist kein Excel- oder OpenDocument-Archiv."
            case .damaged(let s): return "Die Datei ist beschädigt (\(s))."
            case .unsupported(let s): return "Nicht unterstütztes Archivformat (\(s))."
            }
        }
    }

    private let bytes: [UInt8]
    public private(set) var entries: [String: Entry] = [:]

    public init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22, bytes[0] == 0x50, bytes[1] == 0x4B else { throw ZipError.notZip }
        // End of central directory: scan backwards (a comment of up to 64 KB may follow it).
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.damaged("Verzeichnis fehlt") }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        guard p < bytes.count else { throw ZipError.damaged("Verzeichnis außerhalb") }
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { throw ZipError.damaged("Eintrag") }
            let method = u16(p + 10)
            let csize = Int(u32(p + 20))
            let usize = Int(u32(p + 24))
            let nlen = Int(u16(p + 28)), xlen = Int(u16(p + 30)), clen = Int(u16(p + 32))
            let offset = Int(u32(p + 42))
            guard p + 46 + nlen <= bytes.count else { throw ZipError.damaged("Name") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset)
            p += 46 + nlen + xlen + clen
        }
    }

    public func data(_ name: String) throws -> Data? {
        guard let e = entries[name] ?? entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count, u32(h) == 0x0403_4B50 else { throw ZipError.damaged("Kopf von \(name)") }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        let end = start + e.compressedSize
        guard end <= bytes.count else { throw ZipError.damaged("Daten von \(name)") }
        let slice = Array(bytes[start..<end])
        switch e.method {
        case 0: return Data(slice)
        case 8: return Data(try Inflate.decompress(slice, sizeHint: e.uncompressedSize))
        default: throw ZipError.unsupported("Methode \(e.method)")
        }
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
}

/// Raw DEFLATE decoder (RFC 1951), modelled on zlib's reference "puff".
public enum Inflate {
    public enum InflateError: Error { case damaged(String) }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init(lengths: [Int]) throws {
            symbols = [Int](repeating: 0, count: lengths.count)
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var left = 1
            for len in 1...15 {
                left <<= 1
                left -= counts[len]
                if left < 0 { throw InflateError.damaged("Huffman-Code überbestimmt") }
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + counts[len] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbols[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    private struct State {
        let input: [UInt8]
        var pos = 0
        var bitBuf = 0
        var bitCount = 0
        var out: [UInt8] = []

        init(_ input: [UInt8], hint: Int) {
            self.input = input
            out.reserveCapacity(max(hint, input.count * 3))
        }

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuf
            while bitCount < need {
                guard pos < input.count else { throw InflateError.damaged("Daten zu kurz") }
                val |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            bitBuf = val >> need
            bitCount -= need
            return val & ((1 << need) - 1)
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try bits(1)
                let count = h.counts[len]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw InflateError.damaged("ungültiger Code")
        }
    }

    private static let lbase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lext = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let dbase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let dext = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        let lit = try! Huffman(lengths: l)
        let dist = try! Huffman(lengths: [Int](repeating: 5, count: 30))
        return (lit, dist)
    }()

    public static func decompress(_ input: [UInt8], sizeHint: Int = 0) throws -> [UInt8] {
        var s = State(input, hint: sizeHint)
        var last = 0
        repeat {
            last = try s.bits(1)
            switch try s.bits(2) {
            case 0:
                s.bitBuf = 0
                s.bitCount = 0
                guard s.pos + 4 <= input.count else { throw InflateError.damaged("Block zu kurz") }
                let len = Int(input[s.pos]) | Int(input[s.pos + 1]) << 8
                let nlen = Int(input[s.pos + 2]) | Int(input[s.pos + 3]) << 8
                guard len == (~nlen & 0xFFFF) else { throw InflateError.damaged("Längenprüfung") }
                s.pos += 4
                guard s.pos + len <= input.count else { throw InflateError.damaged("Block zu kurz") }
                s.out.append(contentsOf: input[s.pos..<(s.pos + len)])
                s.pos += len
            case 1:
                try codes(&s, fixed.0, fixed.1)
            case 2:
                let nlen = try s.bits(5) + 257, ndist = try s.bits(5) + 1, ncode = try s.bits(4) + 4
                guard nlen <= 286, ndist <= 30 else { throw InflateError.damaged("Tabellengröße") }
                var lengths = [Int](repeating: 0, count: 19)
                for i in 0..<ncode { lengths[order[i]] = try s.bits(3) }
                let lencode = try Huffman(lengths: lengths)
                var all = [Int](repeating: 0, count: nlen + ndist)
                var i = 0
                while i < nlen + ndist {
                    var sym = try s.decode(lencode)
                    if sym < 16 {
                        all[i] = sym
                        i += 1
                    } else {
                        var value = 0
                        if sym == 16 {
                            guard i > 0 else { throw InflateError.damaged("Wiederholung ohne Wert") }
                            value = all[i - 1]
                            sym = 3 + (try s.bits(2))
                        } else if sym == 17 {
                            sym = 3 + (try s.bits(3))
                        } else {
                            sym = 11 + (try s.bits(7))
                        }
                        guard i + sym <= nlen + ndist else { throw InflateError.damaged("zu viele Längen") }
                        for _ in 0..<sym { all[i] = value; i += 1 }
                    }
                }
                guard all[256] != 0 else { throw InflateError.damaged("Endcode fehlt") }
                try codes(&s, try Huffman(lengths: Array(all[0..<nlen])), try Huffman(lengths: Array(all[nlen...])))
            default:
                throw InflateError.damaged("Blocktyp")
            }
        } while last == 0
        return s.out
    }

    private static func codes(_ s: inout State, _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            var sym = try s.decode(lit)
            if sym < 256 {
                s.out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                sym -= 257
                guard sym < 29 else { throw InflateError.damaged("Länge") }
                let len = lbase[sym] + (try s.bits(lext[sym]))
                let dsym = try s.decode(dist)
                guard dsym < 30 else { throw InflateError.damaged("Distanz") }
                let d = dbase[dsym] + (try s.bits(dext[dsym]))
                guard d <= s.out.count else { throw InflateError.damaged("Distanz zu weit") }
                let start = s.out.count - d
                for k in 0..<len { s.out.append(s.out[start + k]) }
            }
        }
    }
}
