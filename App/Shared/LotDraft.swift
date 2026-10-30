import Foundation
import WatchdogCore

/// One purchase as typed in: quantity and price (per piece or in total), parsed with German decimal commas.
struct LotDraft: Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var quantity = ""
    var price = ""
    var priceIsTotal = false

    var parsedQuantity: Double? { Lenient.germanDouble(quantity) }
    var parsedPrice: Double? { Lenient.germanDouble(price) }
    var total: Double? {
        guard let q = parsedQuantity, let p = parsedPrice else { return nil }
        return priceIsTotal ? p : p * q
    }
    var isEmpty: Bool { quantity.trimmingCharacters(in: .whitespaces).isEmpty && price.trimmingCharacters(in: .whitespaces).isEmpty }
    var isValid: Bool { (parsedQuantity ?? 0) > 0 && (parsedPrice ?? -1) >= 0 }
}

extension LotDraft {
    /// Number for editing: German decimal comma, no thousands grouping (so it parses back unambiguously).
    static func plain(_ v: Double, decimals: Int? = nil) -> String {
        if let d = decimals { return String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",") }
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.8f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    init(_ l: Lot) {
        self.init(id: l.id, date: l.day.date, quantity: Self.plain(l.quantity), price: l.hasCost ? Self.plain(l.totalCostEUR, decimals: 2) : "", priceIsTotal: true)
    }

    var lot: Lot {
        Lot(id: id, day: DayKey(date: date, timeZone: .current), quantity: parsedQuantity ?? 0, totalCostEUR: total ?? 0)
    }
}
