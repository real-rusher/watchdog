import Foundation

public enum Indicators {
    /// Simple moving average; nil until `n` values are available.
    public static func sma(_ values: [Double], _ n: Int) -> [Double?] {
        guard n > 0 else { return values.map { $0 } }
        var out = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= n { sum -= values[i - n] }
            if i >= n - 1 { out[i] = sum / Double(n) }
        }
        return out
    }

    /// Exponential moving average seeded with the SMA of the first `n` values.
    public static func ema(_ values: [Double], _ n: Int) -> [Double?] {
        guard n > 0, values.count >= n else { return [Double?](repeating: nil, count: values.count) }
        var out = [Double?](repeating: nil, count: values.count)
        let k = 2.0 / Double(n + 1)
        var prev = values[0..<n].reduce(0, +) / Double(n)
        out[n - 1] = prev
        if n < values.count {
            for i in n..<values.count {
                prev = values[i] * k + prev * (1 - k)
                out[i] = prev
            }
        }
        return out
    }

    public static func line(_ spec: LineSpec, closes: [Double]) -> [Double?] {
        switch spec.kind {
        case .price: return closes.map { $0 }
        case .sma: return sma(closes, spec.length)
        case .ema: return ema(closes, spec.length)
        }
    }

    public struct Crossing: Hashable, Sendable {
        public enum Direction: String, Sendable, Codable { case up, down }
        public let index: Int
        public let direction: Direction
    }

    /// All points where `a` moves from one side of `b` to the other.
    /// Touching the line (equal values) does not count as a crossing.
    public static func crossings(_ a: [Double?], _ b: [Double?]) -> [Crossing] {
        var result: [Crossing] = []
        var lastSign = 0
        for i in 0..<min(a.count, b.count) {
            guard let x = a[i], let y = b[i] else { continue }
            let d = x - y
            let s = d > 0 ? 1 : (d < 0 ? -1 : 0)
            if s == 0 { continue }
            if lastSign != 0 && s != lastSign {
                result.append(Crossing(index: i, direction: s > 0 ? .up : .down))
            }
            lastSign = s
        }
        return result
    }
}
