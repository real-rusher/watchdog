import Foundation

/// Normalizes the currency codes that data providers report.
/// Sub-units such as pence (GBp/GBX) are converted to the main unit so every price in the app
/// is expressed in an ISO 4217 currency.
public enum CurrencyNormalizer {
    public struct Result: Equatable, Sendable {
        public let code: String
        public let factor: Double
    }

    public static func normalize(_ raw: String?) -> Result {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return Result(code: "EUR", factor: 1) }
        switch raw {
        case "GBp", "GBX", "GBx", "gbp-pence": return Result(code: "GBP", factor: 0.01)
        case "ZAc", "ZAC", "ZAx": return Result(code: "ZAR", factor: 0.01)
        case "ILA", "ILa": return Result(code: "ILS", factor: 0.01)
        case "KWF": return Result(code: "KWD", factor: 0.001)
        case "UST", "USDT", "USDt", "USDC", "TESTUSD": return Result(code: "USD", factor: 1)
        case "EUT", "EURT": return Result(code: "EUR", factor: 1)
        case "CNHT": return Result(code: "CNY", factor: 1)
        default: return Result(code: raw.uppercased(), factor: 1)
        }
    }

    /// Currencies the ECB publishes daily reference rates for (plus EUR itself).
    public static let ecb: Set<String> = ["EUR", "USD", "JPY", "BGN", "CZK", "DKK", "GBP", "HUF", "PLN", "RON", "SEK", "CHF", "ISK", "NOK", "TRY", "AUD", "BRL", "CAD", "CNY", "HKD", "IDR", "ILS", "INR", "KRW", "MXN", "MYR", "NZD", "PHP", "SGD", "THB", "ZAR"]

    public static func symbol(_ code: String) -> String {
        switch code {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        case "JPY": return "¥"
        case "CHF": return "CHF"
        default: return code
        }
    }
}
