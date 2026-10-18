import SwiftUI
import UniformTypeIdentifiers
import WatchdogCore

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag("general")
            SourceSettings().tabItem { Label("Datenquellen", systemImage: "antenna.radiowaves.left.and.right") }.tag("sources")
            ExchangeSettings().tabItem { Label("Börsen", systemImage: "building.columns") }.tag("exchanges")
            SignalSettings().tabItem { Label("Signale", systemImage: "light.beacon.max") }.tag("signals")
            NotificationSettingsView().tabItem { Label("Mitteilungen", systemImage: "bell.badge") }.tag("notifications")
            GroupSettings().tabItem { Label("Banken & Themen", systemImage: "folder") }.tag("groups")
        }
        .frame(width: 760, height: 600)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var pickFolder = false
    @State private var pickFile = false

    var body: some View {
        Form {
            Section("Speicherort") {
                LabeledContent("Depotdatei") {
                    Text(model.storagePath).type(12).foregroundStyle(Palette.inkSoft).textSelection(.enabled).lineLimit(3)
                }
                HStack {
                    Button("Ordner ändern …") { pickFolder = true }
                    Button("Vorhandene Datei öffnen …") { pickFile = true }
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.storagePath)])
                    }
                }
                Text("Liegt die Datei in iCloud Drive, ist sie gesichert und später auf iPhone, iPad und anderen Macs verfügbar. Watchdog legt jede Stunde eine Sicherung im Unterordner \u{201E}Backups\u{201C} an.")
                    .type(12).foregroundStyle(Palette.inkSoft)
                if !model.backups.isEmpty {
                    Menu("Sicherung wiederherstellen") {
                        ForEach(model.backups.prefix(30), id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Watchdog_", with: "").replacingOccurrences(of: "_", with: " ")) {
                                model.restoreBackup(url)
                            }
                        }
                    }
                    .frame(maxWidth: 280)
                }
            }
            Section("Aktualisierung") {
                Picker("Kurse aktualisieren alle", selection: Binding(get: { model.local.quoteIntervalMinutes }, set: { v in model.updateLocal { $0.quoteIntervalMinutes = v } })) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) Minuten").tag($0) }
                }
                Text("Nur solange die jeweilige Börse geöffnet hat. Nach Börsenschluss wird einmal der Schlusskurs geholt.").type(12).foregroundStyle(Palette.inkSoft)
            }
            Section("Im Hintergrund") {
                Toggle("Beim Anmelden am Mac starten", isOn: Binding(get: { loginItem }, set: { v in
                    loginError = LoginItem.set(v)
                    loginItem = LoginItem.isEnabled
                }))
                if LoginItem.needsApproval {
                    Text("Bitte in Systemeinstellungen > Allgemein > Anmeldeobjekte erlauben.").type(12).foregroundStyle(Palette.caution)
                }
                if let e = loginError { Text(e).type(12).foregroundStyle(Palette.down) }
                Toggle("Symbol im Dock zeigen", isOn: Binding(get: { model.local.showInDock }, set: { v in model.updateLocal { $0.showInDock = v } }))
                Text("Wird das Fenster geschlossen, läuft Watchdog in der Menüleiste weiter und prüft die Kurse.").type(12).foregroundStyle(Palette.inkSoft)
            }
            Section("Darstellung") {
                HStack {
                    Text("Schriftgröße")
                    Slider(value: Binding(get: { model.local.fontScale }, set: { v in model.updateLocal { $0.fontScale = (v * 20).rounded() / 20 } }), in: 0.85...1.5)
                    Text("\(Int(model.local.fontScale * 100)) %").type(12).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section {
                Text("Watchdog \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").type(13, .medium)
                Text("Kurse kommen aus öffentlich zugänglichen Quellen (Yahoo Finance, OnVista, Financial Times und weitere) und können verzögert sein. Keine Anlageberatung. Schrift: IBM Plex (SIL Open Font License).")
                    .type(12).foregroundStyle(Palette.inkSoft)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { model.moveStorage(to: url) }
        }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.json]) { r in
            if case .success(let url) = r { model.openDepot(at: url) }
        }
    }
}

struct GroupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newBank = ""
    @State private var newTheme = ""

    var body: some View {
        Form {
            Section("Banken und Depots") {
                ForEach(model.depot.banks.sorted { $0.sortIndex < $1.sortIndex }) { b in
                    HStack {
                        TextField("Name", text: Binding(get: { b.name }, set: { v in model.mutate { d in if let i = d.banks.firstIndex(where: { $0.id == b.id }) { d.banks[i].name = v } } }))
                        Text("\(model.depot.positions.filter { $0.bankID == b.id }.count) Werte").type(12).foregroundStyle(Palette.inkSoft)
                        Button { move(bank: b.id, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                        Button { move(bank: b.id, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            model.mutate { d in
                                d.banks.removeAll { $0.id == b.id }
                                for i in d.positions.indices where d.positions[i].bankID == b.id { d.positions[i].bankID = nil }
                            }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Neue Bank", text: $newBank)
                    Button("Anlegen") { let n = newBank.trimmingCharacters(in: .whitespaces); if !n.isEmpty { model.addBank(n); newBank = "" } }
                }
            }
            Section("Themen") {
                ForEach(model.depot.themes.sorted { $0.sortIndex < $1.sortIndex }) { t in
                    HStack {
                        ColorPicker("", selection: Binding(get: { Color(hexString: t.color) ?? Palette.inkSoft }, set: { c in
                            model.mutate { d in if let i = d.themes.firstIndex(where: { $0.id == t.id }) { d.themes[i].color = c.hexString } }
                        }), supportsOpacity: false).labelsHidden().frame(width: 30)
                        TextField("Name", text: Binding(get: { t.name }, set: { v in model.mutate { d in if let i = d.themes.firstIndex(where: { $0.id == t.id }) { d.themes[i].name = v } } }))
                        Text("\(model.depot.positions.filter { $0.themeID == t.id }.count) Werte").type(12).foregroundStyle(Palette.inkSoft)
                        Button { move(theme: t.id, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                        Button { move(theme: t.id, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            model.mutate { d in
                                d.themes.removeAll { $0.id == t.id }
                                for i in d.positions.indices where d.positions[i].themeID == t.id { d.positions[i].themeID = nil }
                            }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Neues Thema", text: $newTheme)
                    Button("Anlegen") { let n = newTheme.trimmingCharacters(in: .whitespaces); if !n.isEmpty { model.addTheme(n); newTheme = "" } }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func move(bank id: UUID, _ delta: Int) {
        model.mutate { d in
            var list = d.banks.sorted { $0.sortIndex < $1.sortIndex }
            guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + delta) else { return }
            list.swapAt(i, i + delta)
            for (n, b) in list.enumerated() { if let k = d.banks.firstIndex(where: { $0.id == b.id }) { d.banks[k].sortIndex = n } }
        }
    }

    private func move(theme id: UUID, _ delta: Int) {
        model.mutate { d in
            var list = d.themes.sorted { $0.sortIndex < $1.sortIndex }
            guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + delta) else { return }
            list.swapAt(i, i + delta)
            for (n, t) in list.enumerated() { if let k = d.themes.firstIndex(where: { $0.id == t.id }) { d.themes[k].sortIndex = n } }
        }
    }
}

extension Color {
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
