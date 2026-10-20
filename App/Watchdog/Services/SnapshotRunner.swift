import SwiftUI
import AppKit
import WatchdogCore

/// CI only: started with `--snapshot <dir>`, waits for data and saves screenshots and a log.
///   --stress            made-up extreme values, many window sizes and font sizes
///   --fixtures <dir>    also runs the import with these files against the live data sources
@MainActor
enum SnapshotRunner {
    static var log = ""
    static var dir: URL!

    static func note(_ s: String) {
        log += s + "\n"
        try? log.write(to: dir.appendingPathComponent("snapshot-log.txt"), atomically: true, encoding: .utf8)
    }

    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    static func run(model: AppModel, dir: URL) async {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = CommandLine.arguments
        note("snapshot start \(Date()) stress=\(args.contains("--stress"))")

        for _ in 0..<150 {
            await sleep(1)
            if !model.isRefreshing && model.snapshot?.lastRefresh != nil { break }
        }
        note("refresh done: \(String(describing: model.lastSummary?.quotesUpdated)) quotes, failures \(String(describing: model.lastSummary?.failures))")
        logValues(model)

        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            note("no window")
            NSApp.terminate(nil)
            return
        }
        note("screen \(NSScreen.main?.visibleFrame ?? .zero), scroller legacy=\(NSScroller.preferredScrollerStyle == .legacy)")
        if args.contains("--stress") {
            await stress(model, window)
        } else {
            await standard(model, window)
            if let i = args.firstIndex(of: "--fixtures"), i + 1 < args.count {
                await importTest(model, window, URL(fileURLWithPath: args[i + 1], isDirectory: true))
            }
        }
        note("done")
        await sleep(0.5)
        NSApp.terminate(nil)
    }

    static func logValues(_ model: AppModel) {
        for r in model.allRows {
            let m = r.metrics
            var parts = [r.position.name]
            parts.append("Kurs " + (m?.priceEUR.map { Format.eur($0) } ?? "-"))
            if let c = m?.currency, c != "EUR", let pl = m?.priceLocal { parts.append("(\(Format.money(pl, c)))") }
            parts.append("Wert " + (m?.valueEUR.map { Format.eur($0) } ?? "-"))
            parts.append("heute " + (m?.dayChangePercent.map { Format.pct($0, signed: true) } ?? "-"))
            parts.append("seit Kauf " + (m?.sincePurchasePercent.map { Format.pct($0, signed: true) } ?? "-"))
            parts.append("1.1. " + (m?.ytdPercent.map { Format.pct($0, signed: true) } ?? "-"))
            parts.append("30T " + (m?.days30Percent.map { Format.pct($0, signed: true) } ?? "-"))
            parts.append("Ampel \(m?.ampel.state.rawValue ?? "-")\(m?.ampel.isFresh == true ? " frisch" : "")")
            if m?.quoteSuspect == true { parts.append("UNBESTÄTIGT") }
            if let f = r.freshness, f.level != .ok { parts.append("Daten: \(f.level) \(f.headline)") }
            if let e = r.status?.lastError { parts.append("Fehler: \(e)") }
            note(parts.joined(separator: " | "))
        }
    }

    static func size(_ window: NSWindow, _ w: CGFloat, _ h: CGFloat = 920) async {
        window.setFrame(NSRect(x: 20, y: 20, width: w, height: h), display: true)
        await sleep(1.2)
    }

    // MARK: Standard run (example depot, live data)

    static func standard(_ model: AppModel, _ window: NSWindow) async {
        await size(window, 1500)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let tag = appearance == .aqua ? "light" : "dark"
            model.selection = nil
            await sleep(1.2)
            capture(window, "1-main-\(tag)")
            let pick = model.allRows.first { $0.metrics?.ampel.state == .red } ?? model.allRows.first
            model.selection = pick?.id
            await sleep(2.5)
            capture(window, "2-detail-\(tag)")
        }

        // Simulated outage.
        NSApp.appearance = NSAppearance(named: .aqua)
        let victims = Array(model.allRows.filter { $0.metrics?.hasData == true && $0.metrics?.ampel.state != .unknown }.prefix(2))
        for (i, r) in victims.enumerated() {
            let since = Date().addingTimeInterval(-Double(70 + i * 25) * 60)
            model.simulatedOutage[r.position.listing.key] = Freshness(
                level: .stale, headline: "seit \(Format.time(since)) keine Kurse",
                detail: "Die Börse ist geöffnet, aber seit \(Format.time(since)) kam kein neuer Kurs. Signale für diesen Wert sind solange nicht aktuell.\nKurs: Yahoo Finance: gedrosselt (HTTP 429), OnVista: keine Antwort",
                lastSuccess: since)
        }
        model.selection = victims.first?.id
        await sleep(2.5)
        capture(window, "7-outage-light")
        model.simulatedOutage = [:]
        model.selection = nil

        model.updateLocal { $0.grouping = .theme }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await sleep(1.2)
        capture(window, "3-themes-dark")
        model.updateLocal { $0.grouping = .bank }

        NSApp.appearance = NSAppearance(named: .aqua)
        await size(window, 760, 860)
        capture(window, "4-narrow-light")
        await size(window, 1500)

        model.editor = .add(query: "Cameco")
        await sleep(9)
        if let sheet = window.attachedSheet { capture(sheet, "5-add-light") } else { note("no sheet for add") }
        model.editor = nil
        await sleep(1)

        for tab in ["sources", "signals", "notifications", "exchanges"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            model.settingsRequest += 1
            await sleep(1.8)
            if let w = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.frame.width > 500 && $0.attachedSheet == nil && !($0.className.contains("StatusBar")) }) {
                capture(w, "6-settings-\(tab)")
                w.close()
            } else {
                note("no settings window for \(tab)")
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Import with real files and live search

    static func importTest(_ model: AppModel, _ window: NSWindow, _ fixtures: URL) async {
        let files = ["depot_openpyxl.xlsx", "depot_libreoffice.xlsx", "depot.ods", "comdirect_umsaetze.csv", "excel_unicode.txt",
                     "mac_roman.csv", "english_broker.csv", "isin_liste.txt", "namen_liste.txt", "depot_alt.xls"]
        var total = 0, found = 0
        for f in files {
            let s = ImportSession(model: model)
            s.load(url: fixtures.appendingPathComponent(f))
            if let e = s.error { note("IMPORT \(f): Hinweis: \(e)"); continue }
            await s.waitUntilResolved()
            note("IMPORT \(f): Blatt \(s.table?.sheetName ?? "-"), Spalten " + zip(s.table?.headers ?? [], s.mapping).map { "\($0)=\($1.label)" }.joined(separator: ", "))
            for d in s.drafts {
                var line = "   \(d.name) [\(d.isin ?? d.wkn ?? d.ticker ?? "")] \(d.quantity.map { Format.qty($0) } ?? "-") Stk, \(d.totalCost.map { Format.money($0, d.costCurrency) } ?? "ohne Preis")"
                if !d.include { line += " (abgewählt)" }
                switch s.states[d.id] {
                case .found(let c)?:
                    line += " => \(c.option.exchangeLabel) \(c.option.ticker)" + (c.note.map { " (\($0))" } ?? "")
                    if d.include { found += 1 }
                case .notFound(let m)?:
                    line += " => NICHT GEFUNDEN: \(m)"
                default:
                    line += " => ?"
                }
                if d.include { total += 1 }
                note(line)
            }
        }
        note("IMPORT gesamt: \(found) von \(total) gefunden")

        // The dialog itself, then committing into the depot.
        NSApp.appearance = NSAppearance(named: .aqua)
        await size(window, 1500)
        model.selection = nil
        model.openImport()
        await sleep(1)
        guard let s = model.importSession else { note("no import session"); return }
        s.load(url: fixtures.appendingPathComponent("depot_openpyxl.xlsx"))
        await s.waitUntilResolved()
        await sleep(1.5)
        if let sheet = window.attachedSheet { capture(sheet, "8-import-xlsx") } else { note("no sheet for import") }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await sleep(1)
        if let sheet = window.attachedSheet { capture(sheet, "8-import-xlsx-dark") }
        NSApp.appearance = NSAppearance(named: .aqua)
        let before = model.depot.positions.count
        await s.commit()
        await sleep(1)
        if let sheet = window.attachedSheet { capture(sheet, "8-import-result") }
        note("IMPORT übernommen: \(model.depot.positions.count - before) neue Positionen, ergänzt: \(s.result?.extended ?? []), nicht gefunden: \(s.result?.notFound ?? [])")
        model.importSession = nil
        for _ in 0..<40 {
            await sleep(1)
            if !model.isRefreshing { break }
        }
        await sleep(3)
        await model.recompute()
        for p in model.depot.positions.suffix(model.depot.positions.count - before) {
            let m = model.metrics(p.id)
            note("NEU \(p.name) \(p.listing.exchangeID) \(p.listing.ticker): Kurs \(m?.priceEUR.map { Format.eur($0) } ?? "-"), Wert \(m?.valueEUR.map { Format.eur($0) } ?? "-"), seit Kauf \(m?.sincePurchasePercent.map { Format.pct($0, signed: true) } ?? "-"), Käufe \(p.lots.count)")
        }
        capture(window, "8-after-import")
        // Empty dialog with the explanation.
        model.openImport()
        await sleep(1)
        if let sheet = window.attachedSheet { capture(sheet, "8-import-empty") }
        model.importSession = nil
    }

    // MARK: Stress run (made-up extreme values)

    static func stress(_ model: AppModel, _ window: NSWindow) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        for w in [1500, 1180, 960, 760, 560] as [CGFloat] {
            await size(window, w)
            model.selection = nil
            await sleep(0.8)
            capture(window, "s-\(Int(w))-light")
        }
        await size(window, 1500)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await sleep(1)
        capture(window, "s-1500-dark")

        // Detail panel next to the table, with a huge and a tiny value.
        NSApp.appearance = NSAppearance(named: .aqua)
        for name in ["Berkshire", "Mini Penny", "Mehrfachkauf", "Absturz", "Keine Daten"] {
            model.selection = model.depot.positions.first { $0.name.hasPrefix(name) }?.id
            await sleep(2.2)
            capture(window, "s-detail-\(name.replacingOccurrences(of: " ", with: "-"))")
        }
        await size(window, 1180)
        model.selection = model.depot.positions.first { $0.name.hasPrefix("Compagnie") }?.id
        await sleep(2)
        capture(window, "s-1180-detail")
        model.selection = nil

        // Larger font.
        for (scale, w) in [(1.4, 1500.0), (1.4, 960.0), (1.6, 1180.0)] {
            model.updateLocal { $0.fontScale = scale }
            await size(window, CGFloat(w))
            capture(window, "s-font\(Int(scale * 10))-\(Int(w))")
        }
        model.updateLocal { $0.fontScale = 1 }

        // Other groupings and sorting.
        await size(window, 1180)
        model.updateLocal { $0.grouping = .theme }
        await sleep(1)
        capture(window, "s-themes")
        model.updateLocal { $0.grouping = .none; $0.sort = .value; $0.sortAscending = false }
        await sleep(1)
        capture(window, "s-list-by-value")
        model.updateLocal { $0.grouping = .bank; $0.sort = .signal; $0.sortAscending = true }

        // Narrow window: detail opens as a sheet.
        await size(window, 760)
        model.selection = model.depot.positions.first { $0.name.hasPrefix("Berkshire") }?.id
        await sleep(2)
        if let sheet = window.attachedSheet { capture(sheet, "s-sheet-detail") } else { note("no detail sheet") }
        model.selection = nil
        await sleep(1)

        // Every row at once (the window only shows the top): rendered off screen at three widths.
        for (w, scale) in [(1400.0, 1.0), (900.0, 1.0), (1100.0, 1.4)] {
            for dark in [false, true] where !(dark && w != 1400) {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                renderTable(model, width: CGFloat(w), scale: CGFloat(scale), name: "s-table-\(Int(w))-\(Int(scale * 10))\(dark ? "-dark" : "")")
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    /// The complete table without scrolling, to check every row for overlaps.
    static func renderTable(_ model: AppModel, width: CGFloat, scale: CGFloat, name: String) {
        let view = FullTable(width: width)
            .environment(model)
            .environment(\.uiScale, scale)
            .environment(\.locale, Locale(identifier: "de_DE"))
            .frame(width: width)
            .background(Palette.canvas)
        let r = ImageRenderer(content: view)
        r.scale = 2
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            note("render failed \(name)")
            return
        }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        note("rendered \(name) \(Int(img.size.width))x\(Int(img.size.height))")
    }

    static func capture(_ window: NSWindow, _ name: String) {
        let id = CGWindowID(window.windowNumber)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]), cg.width > 10 {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
                note("captured \(name) \(cg.width)x\(cg.height)")
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { note("capture failed \(name)"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            note("captured \(name) via cacheDisplay")
        }
    }
}

/// Header, section headers and all rows in a plain stack (no scrolling), same views as the real table.
private struct FullTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    var width: CGFloat

    var body: some View {
        let cols = Column.visible(width: width, scale: scale, hidden: model.local.hiddenColumns)
        VStack(spacing: 0) {
            SummaryStrip()
            HeaderRow(columns: cols)
            ForEach(model.sections) { s in
                SectionHeaderRow(section: s, columns: cols)
                ForEach(Array(s.rows.enumerated()), id: \.element.id) { i, r in
                    QuoteRow(row: r, columns: cols, zebra: i % 2 == 1)
                }
            }
        }
    }
}
