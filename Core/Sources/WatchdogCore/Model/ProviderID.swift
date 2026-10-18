import Foundation

/// All data sources Watchdog knows. Raw values are stable and stored in files.
public enum ProviderID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case yahoo
    case onvista
    case ft
    case lstc
    case tradegate
    case bitfinex
    case eodhd
    case twelvedata
    case alphavantage
    case finnhub

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yahoo: return "Yahoo Finance"
        case .onvista: return "OnVista"
        case .ft: return "Financial Times"
        case .lstc: return "Lang & Schwarz"
        case .tradegate: return "Tradegate"
        case .bitfinex: return "Bitfinex"
        case .eodhd: return "EODHD"
        case .twelvedata: return "Twelve Data"
        case .alphavantage: return "Alpha Vantage"
        case .finnhub: return "Finnhub"
        }
    }

    public var shortName: String {
        switch self {
        case .yahoo: return "YF"
        case .onvista: return "OV"
        case .ft: return "FT"
        case .lstc: return "LS"
        case .tradegate: return "TG"
        case .bitfinex: return "BFX"
        case .eodhd: return "EOD"
        case .twelvedata: return "12D"
        case .alphavantage: return "AV"
        case .finnhub: return "FH"
        }
    }

    public var requiresKey: Bool {
        switch self {
        case .eodhd, .twelvedata, .alphavantage, .finnhub: return true
        default: return false
        }
    }

    /// Where a user gets a free key (for keyed providers).
    public var signupURL: URL? {
        switch self {
        case .eodhd: return URL(string: "https://eodhd.com/register")
        case .twelvedata: return URL(string: "https://twelvedata.com/register")
        case .alphavantage: return URL(string: "https://www.alphavantage.co/support/#api-key")
        case .finnhub: return URL(string: "https://finnhub.io/register")
        default: return nil
        }
    }

    /// Honest one-line description shown in the settings.
    public var summary: String {
        switch self {
        case .yahoo: return "Weltweit fast alle Börsen, kostenlos, inoffiziell. Drosselt bei sehr vielen Abrufen."
        case .onvista: return "Deutsche Handelsplätze inkl. Tradegate, gettex, LS Exchange, dazu USA, London, Schweiz. Kostenlos, inoffiziell."
        case .ft: return "Weltweite Börsen inkl. Tokio, Australien, Kanada, Skandinavien. Tagesschlusskurse, kostenlos, inoffiziell."
        case .lstc: return "Kurse direkt von Lang & Schwarz für LS Exchange. Kostenlos, inoffiziell."
        case .tradegate: return "Aktueller Kurs direkt von Tradegate (ohne Historie). Kostenlos, inoffiziell."
        case .bitfinex: return "Kryptowährungen an Bitfinex. Offizielle öffentliche API, kostenlos."
        case .eodhd: return "Offizielle API, Gratis-Schlüssel nur 20 Abrufe/Tag. Bezahlt ab ca. 20 $/Monat sehr stabil."
        case .twelvedata: return "Offizielle API, Gratis-Schlüssel 800 Abrufe/Tag, gratis vor allem USA."
        case .alphavantage: return "Offizielle API, Gratis-Schlüssel 25 Abrufe/Tag."
        case .finnhub: return "Offizielle API, gratis nur aktuelle Kurse für US-Börsen."
        }
    }

    /// Default fallback order. Users can reorder this in the settings.
    public static let defaultOrder: [ProviderID] = [.yahoo, .onvista, .ft, .lstc, .tradegate, .bitfinex, .eodhd, .twelvedata, .finnhub, .alphavantage]
}
