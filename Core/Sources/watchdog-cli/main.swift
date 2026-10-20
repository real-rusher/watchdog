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

/// Cross-checks every source against the others: same price, quote time inside the trading hours of the venue,
/// same reference closes for "seit 1.1." and "30 Tage".
func verify() async {
    print("# Werteprüfung (\(Date()))\n")
    var problems: [String] = []
    let today = DayKey.today(in: .berlin)
    let ytdBase = DayKey(year: today.year - 1, month: 12, day: 31)
    for c in cases where c.only == nil {
        guard let ex = catalog[c.exchange] else { continue }
        let ref = SecurityRef(name: c.name, isin: c.isin, wkn: nil, listing: Listing(exchangeID: c.exchange, ticker: c.ticker, symbols: c.symbols), assetType: .stock)
        print("## \(c.name) @ \(ex.name)")
        struct Row { var p: ProviderID; var price: Double; var time: Date; var cur: String; var ytd: Double?; var d30: Double?; var last: DayKey? }
        var rows: [Row] = []
        for pid in ProviderID.defaultOrder where !pid.requiresKey {
            guard let p = registry[pid], p.supports(ex), p.capabilities.contains(.quote) else { continue }
            do {
                let sym = try await p.resolveSymbol(ref, exchange: ex, env: env)
                let q = try await p.quote(symbol: sym, exchange: ex, env: env)
                var r = Row(p: pid, price: q.price, time: q.time, cur: q.currency)
                if p.capabilities.contains(.history), let h = try? await p.history(symbol: sym, exchange: ex, from: ytdBase.adding(days: -20), env: env) {
                    r.ytd = h.bars.last { $0.day <= ytdBase }?.close
                    r.d30 = h.bars.last { $0.day <= today.adding(days: -30) }?.close
                    r.last = h.bars.last?.day
                }
                rows.append(r)
            } catch {
                print("  \(pad(pid.displayName, 16)) nicht verfügbar: \(String(describing: error).prefix(90))")
            }
        }
        guard !rows.isEmpty else { problems.append("\(c.name) @ \(ex.name): keine Quelle"); continue }
        // Reference: the newest quote; compare only quotes of the same trading day.
        let newestDay = rows.map { DayKey(date: $0.time, timeZone: ex.tz) }.max()!
        let sameDay = rows.filter { DayKey(date: $0.time, timeZone: ex.tz) == newestDay }
        let med = sameDay.map(\.price).sorted()[sameDay.count / 2]
        for r in rows {
            let dev = (r.price / med - 1) * 100
            let local = DayKey(date: r.time, timeZone: ex.tz)
            // A quote must carry a time inside the venue's trading hours (20 minutes tolerance for the closing auction).
            let inHours = ex.kind == .crypto || ex.isOpen(at: r.time) || ex.isOpen(at: r.time.addingTimeInterval(-20 * 60)) || ex.isOpen(at: r.time.addingTimeInterval(20 * 60))
            var line = "  \(pad(r.p.displayName, 16)) \(pad(String(format: "%.4f %@", r.price, r.cur), 18)) \(pad(Format.time(r.time, tz: ex.tz), 10))"
            line += local == newestDay ? " Abw. \(String(format: "%+.2f", dev)) %" : " (Vortag)"
            line += " | 31.12.: \(r.ytd.map { String(format: "%.4f", $0) } ?? "-") | vor 30 T: \(r.d30.map { String(format: "%.4f", $0) } ?? "-") | Verlauf bis \(r.last?.iso ?? "-")"
            if local == newestDay && abs(dev) > 1.5 { line += "  << ABWEICHUNG"; problems.append("\(c.name) @ \(ex.name): \(r.p.displayName) weicht \(String(format: "%+.1f", dev)) % ab") }
            if !inHours { line += "  << ZEIT AUSSERHALB DER HANDELSZEIT"; problems.append("\(c.name) @ \(ex.name): \(r.p.displayName) Kurszeit \(Format.time(r.time, tz: ex.tz)) außerhalb der Handelszeit (falscher Handelsplatz?)") }
            print(line)
        }
        let ytds = rows.compactMap(\.ytd)
        if let lo = ytds.min(), let hi = ytds.max(), lo > 0, (hi / lo - 1) * 100 > 1.5 {
            problems.append("\(c.name) @ \(ex.name): Schlusskurs 31.12. unterschiedlich (\(String(format: "%.3f..%.3f", lo, hi)))")
        }
        print("")
    }
    print("# Ergebnis: \(problems.isEmpty ? "keine Auffälligkeiten" : "\(problems.count) Auffälligkeiten")")
    for p in problems { print("  - \(p)") }
}

/// watchdog-cli import FILE [--resolve] : reads a file like the import dialog and optionally finds every listing live.
func importFile() async {
    guard args.count >= 2 else { print("usage: import FILE [--resolve]"); return }
    let url = URL(fileURLWithPath: args[1])
    do {
        let data = try Data(contentsOf: url)
        let started = Date()
        let sheets = try ImportFile.sheets(data: data, filename: url.lastPathComponent)
        let t = CSVImport.bestTable(sheets)
        let map = CSVImport.guessMapping(t.headers, rows: t.rows)
        let drafts = CSVImport.drafts(t, mapping: map, catalog: catalog)
        print("# Import \(url.lastPathComponent): Blatt \(t.sheetName ?? "-"), \(t.rows.count) Zeilen, \(drafts.count) Werte, gelesen in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        for (h, f) in zip(t.headers, map) { print("  \(pad(h, 28)) -> \(f.label)") }
        let engine = MarketEngine(cacheDir: nil)
        let depot = DepotFile()
        var found = 0
        for d in drafts {
            let qty = d.quantity.map { Format.qty($0) } ?? "-"
            let cost = d.totalCost.map { Format.money($0, d.costCurrency) } ?? "-"
            var line = "  \(pad(d.name, 30)) \(pad(d.isin ?? d.wkn ?? d.ticker ?? "", 13)) \(pad(qty, 9)) \(pad(cost, 14)) lots \(d.lots.count)"
            if !d.include { line += " [aus]" }
            if args.contains("--resolve") && d.include {
                let outcome = await ImportResolver.resolve(d, target: "TGAT", catalog: catalog) { q in
                    await engine.search(q, depot: depot, keys: keys)
                }
                switch outcome {
                case .found(let c):
                    found += 1
                    line += "  => \(c.option.exchangeLabel) \(c.option.ticker) (\(c.option.providers.map(\.shortName).joined(separator: "+")))"
                    if let n = c.note { line += " [\(n)]" }
                case .notFound(let m):
                    line += "  => NICHT GEFUNDEN: \(m)"
                }
            }
            print(line)
            for i in d.issues { print("      ! \(i)") }
            for n in d.notes { print("      i \(n)") }
        }
        if args.contains("--resolve") { print("  gefunden: \(found) von \(drafts.filter(\.include).count)") }
    } catch {
        print("FEHLER: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
}

switch mode {
case "venues":
    for q in args.dropFirst() {
        print("# OnVista \(q)")
        do { for l in try await OnVistaProvider().debugVenues(q, env: env) { print(l) } } catch { print("FEHLER \(error)") }
    }
case "verify":
    await verify()
case "import":
    await importFile()
case "search":
    for q in args.dropFirst() { await search(q) }
case "depot":
    await depot()
case "ntfy":
    await ntfy()
default:
    await probe()
}
