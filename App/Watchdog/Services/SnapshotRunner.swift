import SwiftUI
import AppKit
import WatchdogCore

/// CI only: started with `--snapshot <dir>`, loads the example depot, waits for live data and saves screenshots.
@MainActor
enum SnapshotRunner {
    static func run(model: AppModel, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log = "snapshot start \(Date())\n"
        func note(_ s: String) { log += s + "\n"; try? log.write(to: dir.appendingPathComponent("snapshot-log.txt"), atomically: true, encoding: .utf8) }

        // Wait for the data.
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !model.isRefreshing && model.snapshot?.lastRefresh != nil { break }
        }
        note("refresh done: \(String(describing: model.lastSummary?.quotesUpdated)) quotes, failures \(String(describing: model.lastSummary?.failures))")
        for p in model.depot.positions {
            let m = model.metrics(p.id)
            note("\(p.name): \(m?.priceEUR.map { Format.eur($0) } ?? "-") \(m?.ampel.state.rawValue ?? "-") \(model.snapshot?.status[p.listing.key]?.lastError ?? "")")
        }
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            note("no window")
            NSApp.terminate(nil)
            return
        }
        window.setFrame(NSRect(x: 40, y: 40, width: 1500, height: 920), display: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let tag = appearance == .aqua ? "light" : "dark"
            model.selection = nil
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            capture(window, dir, "1-main-\(tag)", note)

            // Detail of a position with a signal.
            let pick = model.allRows.first { $0.metrics?.ampel.state == .red } ?? model.allRows.first
            model.selection = pick?.id
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            capture(window, dir, "2-detail-\(tag)", note)
        }

        // Theme grouping.
        model.selection = nil
        model.updateLocal { $0.grouping = .theme }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture(window, dir, "3-themes-dark", note)
        model.updateLocal { $0.grouping = .bank }

        // Narrow window.
        NSApp.appearance = NSAppearance(named: .aqua)
        window.setFrame(NSRect(x: 40, y: 40, width: 760, height: 860), display: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture(window, dir, "4-narrow-light", note)
        window.setFrame(NSRect(x: 40, y: 40, width: 1500, height: 920), display: true)

        // Add dialog with a live search.
        model.editor = .add(query: "Cameco")
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        if let sheet = window.attachedSheet { capture(sheet, dir, "5-add-light", note) } else { note("no sheet for add") }
        model.editor = nil
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Settings tabs.
        for tab in ["sources", "signals", "notifications", "exchanges"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            model.settingsRequest += 1
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if let w = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.frame.width > 500 && $0.attachedSheet == nil && !($0.className.contains("StatusBar")) }) {
                capture(w, dir, "6-settings-\(tab)", note)
            } else {
                note("no settings window for \(tab): " + NSApp.windows.map { "\($0.className) \($0.frame)" }.joined(separator: "; "))
            }
        }

        // Import dialog with a sample list.
        model.importPrefill = """
        Bezeichnung;ISIN;Stück;Kaufkurs;Kaufdatum;Börse;Depot;Thema
        Cameco Corp.;CA13321L1085;120;14,50;15.03.2021;Tradegate;Comdirect;Uran
        Toyota Motor;JP3633400001;100;11,50;17.05.2019;Tokio;Sparkasse;Technologie
        Equinor ASA;NO0010096985;80;11,50;02.11.2020;Oslo;Comdirect;Öl & Gas
        Kazatomprom;US63253R2013;;;;London;;Uran
        """
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) { main.makeKeyAndOrderFront(nil) }
        model.showImport = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let sheet = window.attachedSheet { capture(sheet, dir, "8-import-light", note) } else { note("no sheet for import") }
        model.showImport = false
        note("done")
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }

    static func capture(_ window: NSWindow, _ dir: URL, _ name: String, _ note: (String) -> Void) {
        // 1) The window server image (includes title bar and toolbar).
        let id = CGWindowID(window.windowNumber)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]),
           cg.width > 10 {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
                note("captured \(name) via window server \(cg.width)x\(cg.height)")
                return
            }
        }
        // 2) Fallback: draw the view hierarchy.
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { note("capture failed \(name)"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            note("captured \(name) via cacheDisplay")
        }
    }
}
