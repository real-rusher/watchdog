import Foundation
import WatchdogCore

// Command line helper used in CI to check every data source against the live APIs.
//   watchdog-cli probe      provider matrix (resolve, quote, history)
//   watchdog-cli search Q   merged search results
//   watchdog-cli depot      full refresh of the example depot and the resulting table

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "probe"
let http = HTTPClient()
let catalog = ExchangeCatalog()
let keys: [ProviderID: String] = {
    var k: [ProviderID: String] = [:]
    for p in ProviderID.allCases where p.requiresKey {
        let env = ProcessInfo.processInfo.environment["\(p.rawValue.uppercased())_KEY"]
        k[p] = env ?? (p == .finnhub ? nil : "demo")
    }
    return k
}()
let env = ProviderEnvironment(http: http, keys: keys, catalog: catalog)
let registry = ProviderRegistry()

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

struct Case {
    var name: String
    var isin: String?
    var exchange: ExchangeID
    var ticker: String
    var symbols: [String: String] = [:]
    var only: [ProviderID]? = nil
}

let cases: [Case] = [
    Case(name: "SAP", isin: "DE0007164600", exchange: "XETR", ticker: "SAP"),
    Case(name: "SAP", isin: "DE0007164600", exchange: "TGAT", ticker: "SAP"),
    Case(name: "Cameco", isin: "CA13321L1085", exchange: "GETX", ticker: "CJ6"),
    Case(name: "SAP", isin: "DE0007164600", exchange: "LSEX", ticker: "SAP"),
    Case(name: "SAP", isin: "DE0007164600", exchange: "XFRA", ticker: "SAP"),
    Case(name: "Toyota Motor", isin: "JP3633400001", exchange: "XTKS", ticker: "7203"),
    Case(name: "Yellow Cake", isin: "JE00BF50RG45", exchange: "XLON", ticker: "YCA"),
    Case(name: "Cameco", isin: "CA13321L1085", exchange: "XTSE", ticker: "CCO"),
    Case(name: "Skyharbour Resources", exchange: "XTSX", ticker: "SYH"),
    Case(name: "Apple", isin: "US0378331005", exchange: "XNAS", ticker: "AAPL"),
    Case(name: "Cameco", isin: "CA13321L1085", exchange: "XNYS", ticker: "CCJ"),
    Case(name: "Paladin Energy", isin: "AU000000PDN8", exchange: "OOTC", ticker: "PALAF"),
    Case(name: "TotalEnergies", isin: "FR0000120271", exchange: "XPAR", ticker: "TTE"),
    Case(name: "Eni", isin: "IT0003132476", exchange: "XMIL", ticker: "ENI"),
    Case(name: "Nestle", isin: "CH0038863350", exchange: "XSWX", ticker: "NESN"),
    Case(name: "Equinor", isin: "NO0010096985", exchange: "XOSL", ticker: "EQNR"),
    Case(name: "Paladin Energy", isin: "AU000000PDN8", exchange: "XASX", ticker: "PDN"),
    Case(name: "Ericsson B", isin: "SE0000108656", exchange: "SSME", ticker: "ERIC B"),
    Case(name: "Bitcoin", exchange: "BFX", ticker: "BTCUSD"),
    // Demo keys of the keyed providers only work for these:
    Case(name: "IBM", isin: "US4592001014", exchange: "XNYS", ticker: "IBM", only: [.alphavantage]),
]

func probe() async {
    print("# Provider-Matrix (\(Date()))\n")
    for c in cases {
        guard let ex = catalog[c.exchange] else { print("!! unbekannte Börse \(c.exchange)"); continue }
        let ref = SecurityRef(name: c.name, isin: c.isin, wkn: nil, listing: Listing(exchangeID: c.exchange, ticker: c.ticker, symbols: c.symbols), assetType: .stock)
        print("## \(c.name) @ \(ex.name)")
        for pid in ProviderID.defaultOrder {
            if let only = c.only, !only.contains(pid) { continue }
            guard let p = registry[pid], p.supports(ex) else { continue }
            if pid.requiresKey && keys[pid] == nil { continue }
            var line = "  " + pad(pid.displayName, 16)
            do {
                let sym = try await p.resolveSymbol(ref, exchange: ex, env: env)
                line += pad(sym, 34)
                if p.capabilities.contains(.quote) {
                    do {
                        let q = try await p.quote(symbol: sym, exchange: ex, env: env)
                        line += " Kurs " + pad(String(format: "%.3f %@", q.price, q.currency), 16) + " " + pad(Format.time(q.time, tz: ex.tz), 10)
                        if let pc = q.previousClose { line += " vorher " + String(format: "%.3f", pc) }
                    } catch { line += " Kurs-FEHLER \(error)" }
                }
                if p.capabilities.contains(.history) {
                    do {
                        let h = try await p.history(symbol: sym, exchange: ex, from: DayKey.today().adding(days: -420), env: env)
                        let first = h.bars.first?.day.iso ?? "-", last = h.bars.last?.day.iso ?? "-"
                        line += " | Verlauf \(h.bars.count) Tage \(first)..\(last) \(h.currency) letzter \(String(format: "%.3f", h.bars.last?.close ?? 0))"
                    } catch { line += " | Verlauf-FEHLER \(error)" }
                }
            } catch {
                line += "Symbol-FEHLER \(error)"
            }
            print(line)
        }
        print("")
    }
}

func search(_ q: String) async {
    let router = DataRouter(registry: registry)
    let r = await router.search(q, prefs: SourcePreferences(), env: env)
    print("# Suche \(q): \(r.count) Treffer")
    for c in r.sorted(by: { ($0.exchangeID ?? "~", $0.provider.rawValue) < ($1.exchangeID ?? "~", $1.provider.rawValue) }) {
        print("  " + pad(c.provider.shortName, 4) + pad(c.exchangeID ?? "?", 6) + pad(c.exchangeLabel, 22) + pad(c.ticker, 10) + pad(c.symbol, 34) + pad(c.currency ?? "", 5) + c.name + (c.isin.map { " " + $0 } ?? ""))
    }
}

func depot() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-cli-cache")
    let engine = MarketEngine(cacheDir: dir, http: http)
    let d = DepotFile.example()
    let t0 = Date()
    let s = await engine.refresh(depot: d, keys: keys, force: true)
    print("# Depot-Aktualisierung: \(s.quotesUpdated) Kurse, \(s.historiesUpdated) Verläufe, \(s.failures) Fehler, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n")
    let snap = await engine.snapshot(depot: d)
    for p in d.positions {
        let m = snap.metrics[p.id]
        let st = snap.status[p.listing.key]
        var line = pad(p.name, 22) + pad(p.listing.exchangeID, 6)
        if let m, let pe = m.priceEUR {
            line += pad(Format.eur(pe), 14) + pad(m.dayChangePercent.map { Format.pct($0, signed: true) } ?? "-", 9)
            line += pad(m.days30Percent.map { Format.pct($0, signed: true) } ?? "-", 9) + pad(m.ytdPercent.map { Format.pct($0, signed: true) } ?? "-", 9)
            line += pad(m.ampel.state.rawValue, 7) + pad(m.ampel.distancePercent.map { Format.pct($0, signed: true) } ?? "-", 9)
            line += " Q:\(st?.quoteSource?.shortName ?? "-") H:\(st?.historySource?.shortName ?? "-") n=\(m.historyCount)"
        } else {
            line += "KEINE DATEN"
        }
        if let e = st?.lastError { line += "\n      " + e.replacingOccurrences(of: "\n", with: "\n      ") }
        print(line)
    }
    print("\nFX:", snap.fx.rates.keys.sorted().map { "\($0)=\(snap.fx.rates[$0]?.count ?? 0)" }.joined(separator: " "))
    print("Health:", snap.health.map { "\($0.key.rawValue): ok \($0.value.successCount) / err \($0.value.failureCount)" }.sorted().joined(separator: ", "))
}

/// Sends a message with umlauts to a throw-away ntfy topic and reads it back.
func ntfy() async {
    var s = NotificationSettings()
    s.ntfyEnabled = true
    let n = NtfyNotifier(settings: s, http: http)
    do {
        try await n.send(title: "Öl & Gas · Tradegate", body: "Durchbruch der 200-Tage-Linie nach unten am 16.10. · Kurs 72,54 €", severity: .alarm)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let (data, _) = try await http.get(URL(string: "https://ntfy.sh/\(s.ntfyTopic)/json?poll=1&since=all")!)
        print("ntfy topic \(s.ntfyTopic):")
        print(String(data: data, encoding: .utf8) ?? "")
    } catch {
        print("ntfy FEHLER \(error)")
    }
}

switch mode {
case "search":
    for q in args.dropFirst() { await search(q) }
case "depot":
    await depot()
case "ntfy":
    await ntfy()
default:
    await probe()
}
