import SwiftUI
import AppKit
import WatchdogCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Typo.registerFonts()
    }

    /// Closing the window keeps Watchdog running in the menu bar so it can keep watching.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CommandLine.arguments.contains("--snapshot")
    }
}

@main
struct WatchdogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    /// German dates and numbers everywhere, independent of the system language.
    static let german = Locale(identifier: "de_DE")

    init() {
        Typo.registerFonts()
    }

    var body: some Scene {
        Window("Watchdog", id: "main") {
            MainView()
                .environment(model)
                .environment(\.uiScale, CGFloat(model.local.fontScale))
                .environment(\.locale, Self.german)
                .frame(minWidth: 560, minHeight: 420)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { WatchdogCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.uiScale, CGFloat(model.local.fontScale))
                .environment(\.locale, Self.german)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(\.uiScale, 1)
                .environment(\.locale, Self.german)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    var model: AppModel
    var body: some View {
        let t = model.totals
        let red = t.counts[.red] ?? 0
        HStack(spacing: 3) {
            Image("MenuIcon")
            if red > 0 { Text("\(red)") }
            // Data outage: a small warning sign next to the count.
            if !t.stale.isEmpty { Image(systemName: "exclamationmark.triangle") }
        }
        .onAppear { model.start() }
    }
}

struct WatchdogCommands: Commands {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Wertpapier hinzufügen …") {
                openWindow(id: "main")
                model.editor = .add(query: nil)
            }
            .keyboardShortcut("n")
            Button("Importieren …") {
                openWindow(id: "main")
                model.openImport()
            }
            .keyboardShortcut("i")
        }
        CommandMenu("Depot") {
            Button("Kurse aktualisieren") { model.refresh(force: true) }
                .keyboardShortcut("r")
            Divider()
            Picker("Gruppierung", selection: Binding(get: { model.local.grouping }, set: { g in model.updateLocal { $0.grouping = g } })) {
                ForEach(Grouping.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Schrift größer") { model.updateLocal { $0.fontScale = min(1.6, $0.fontScale + 0.1) } }
                .keyboardShortcut("+")
            Button("Schrift kleiner") { model.updateLocal { $0.fontScale = max(0.8, $0.fontScale - 0.1) } }
                .keyboardShortcut("-")
            Button("Normale Schriftgröße") { model.updateLocal { $0.fontScale = 1 } }
                .keyboardShortcut("0")
        }
    }
}
