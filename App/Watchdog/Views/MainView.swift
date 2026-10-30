import SwiftUI
import WatchdogCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let wide = geo.size.width >= 1080
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Totals only make sense with values; an empty depot shows just the start page.
                    if !model.depot.positions.isEmpty {
                        SummaryStrip()
                        Divider().overlay(Palette.rule)
                    }
                    if model.depot.positions.isEmpty {
                        EmptyDepotView()
                    } else {
                        QuoteTable(availableWidth: wide && model.selection != nil ? geo.size.width - detailWidth(geo.size.width) : geo.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide, let id = model.selection, model.position(id) != nil {
                    Divider().overlay(Palette.rule)
                    DetailView(positionID: id)
                        .frame(width: detailWidth(geo.size.width))
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Palette.canvas)
            .sheet(isPresented: Binding(get: { !wide && model.selection != nil && model.editor == nil && !model.showImport },
                                        set: { if !$0 { model.selection = nil } })) {
                if let id = model.selection {
                    DetailView(positionID: id, showsClose: true)
                        .environment(model)
                        .environment(\.uiScale, scale)
                        .environment(\.locale, WatchdogApp.german)
                        .frame(minWidth: min(560, geo.size.width - 40), idealWidth: 560, minHeight: min(640, geo.size.height - 40), idealHeight: 720)
                }
            }
        }
        .toolbar { MainToolbar() }
        .navigationTitle(model.isExampleDepot ? "Watchdog (Beispieldepot)" : "Watchdog")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Name, ISIN, Kürzel")
        .sheet(item: $model.editor) { req in
            PositionEditor(request: req)
                .environment(model)
                .environment(\.uiScale, scale)
                .environment(\.locale, WatchdogApp.german)
        }
        .sheet(item: $model.importSession) { session in
            ImportView(session: session)
                .environment(model)
                .environment(\.uiScale, scale)
                .environment(\.locale, WatchdogApp.german)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if !model.marked.isEmpty { SelectionBar() }
                if let u = model.undoText {
                    NoticeBanner(text: u, actionTitle: "Rückgängig", action: { model.undoDelete() }, seconds: 15) { model.undoText = nil }
                }
                if let n = model.notice {
                    NoticeBanner(text: n) { model.notice = nil }
                }
            }
            .padding(.bottom, 18)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } }),
                            titleVisibility: .visible, presenting: model.deleteRequest) { req in
            switch req {
            case .positions(let ids):
                Button(ids.count == 1 ? "Löschen" : "\(ids.count) Werte löschen", role: .destructive) { model.remove(ids) }
            case .all:
                Button("Alle Werte entfernen", role: .destructive) { model.removeAll(keepGroups: true) }
                Button("Werte, Banken und Themen entfernen", role: .destructive) { model.removeAll(keepGroups: false) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { req in
            Text(deleteMessage(req))
        }
        .animation(.easeOut(duration: 0.18), value: model.selection)
        .onChange(of: model.settingsRequest) { _, _ in openSettings() }
    }

    private var deleteTitle: String {
        switch model.deleteRequest {
        case .positions(let ids)?:
            if ids.count == 1, let p = model.position(ids.first) { return "\(p.name) löschen?" }
            return "\(ids.count) Werte löschen?"
        case .all?: return "Alle \(model.depot.positions.count) Werte entfernen?"
        case nil: return ""
        }
    }

    private func deleteMessage(_ req: DeleteRequest) -> String {
        let undo = "Direkt danach lässt sich das mit \u{201E}Rückgängig\u{201C} zurücknehmen; außerdem legt Watchdog vorher eine Sicherung an (Einstellungen > Allgemein)."
        switch req {
        case .positions(let ids):
            let names = model.depot.positions.filter { ids.contains($0.id) }.map(\.name)
            let list = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " und \(names.count - 6) weitere" : "")
            return "Die Werte und ihre Käufe werden entfernt: \(list). " + undo
        case .all:
            return "Das Depot wird leer. Einstellungen, Regeln, Börsen und der Mitteilungskanal fürs iPhone bleiben erhalten. Banken und Themen können bleiben (praktisch zum neu Eintragen) oder mit entfernt werden. " + undo
        }
    }

    private func detailWidth(_ total: CGFloat) -> CGFloat {
        min(560, max(420, total * 0.36))
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Gruppierung", selection: Binding(get: { model.local.grouping }, set: { g in model.updateLocal { $0.grouping = g } })) {
                Text("Banken").tag(Grouping.bank)
                Text("Themen").tag(Grouping.theme)
                Text("Liste").tag(Grouping.none)
            }
            .pickerStyle(.segmented)
            .help("Tabelle nach Bank, nach Thema oder als eine Liste zeigen")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            RefreshButton()
            SourceMenu()
            Button {
                model.openImport()
            } label: {
                Label("Importieren", systemImage: "square.and.arrow.down")
            }
            .help("Mehrere Werte aus CSV oder Excel übernehmen")
            Button {
                model.editor = .add(query: nil)
            } label: {
                Label("Hinzufügen", systemImage: "plus")
            }
            .help("Wertpapier hinzufügen (⌘N)")
        }
    }
}

struct RefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.refresh(force: true)
        } label: {
            if model.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if model.progressTotal > 0 {
                        Text("\(model.progressDone)/\(model.progressTotal)").type(12).monospacedDigit()
                    }
                }
            } else {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
        }
        .help(model.lastRefreshText + ". Klicken zum sofortigen Aktualisieren (⌘R).")
        .disabled(model.isRefreshing)
    }
}

/// Quick switch for the first data source.
struct SourceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Zuerst fragen") {
                ForEach(ProviderID.defaultOrder) { p in
                    let usable = !p.requiresKey || model.local.keys[p] != nil
                    Button {
                        model.mutate { $0.sources.makePrimary(p) }
                        model.refresh(force: true)
                    } label: {
                        if model.depot.sources.primary == p {
                            Label(p.displayName, systemImage: "checkmark")
                        } else {
                            Text(p.displayName + (usable ? "" : " (Schlüssel fehlt)"))
                        }
                    }
                    .disabled(!usable)
                }
            }
            Toggle("Bei Fehlern automatisch wechseln", isOn: Binding(get: { model.depot.sources.autoFallback },
                                                                   set: { v in model.mutate { $0.sources.autoFallback = v } }))
            Divider()
            SettingsLink { Text("Datenquellen verwalten …") }
        } label: {
            Label(model.depot.sources.primary.displayName, systemImage: "antenna.radiowaves.left.and.right")
        }
        .help("Datenquelle: \(model.depot.sources.primary.displayName) zuerst")
    }
}

struct NoticeBanner: View {
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var seconds: Double = 7
    var close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text).type(13).foregroundStyle(Palette.ink).lineLimit(3)
            if let t = actionTitle, let action {
                Button(t, action: action).buttonStyle(.borderless).type(13, .semibold)
            }
            Button("OK", action: close).buttonStyle(.borderless).type(13, actionTitle == nil ? .semibold : .regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.signal).frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2)).padding(.vertical, 6) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .task(id: text) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            close()
        }
    }
}

struct EmptyDepotView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Noch keine Werte im Depot").type(26, .semibold).foregroundStyle(Palette.ink)
            Text("Lege deine Aktien an, dann zeigt Watchdog für jede, ob sie über oder unter ihrer 200-Tage-Linie steht, und meldet sich, sobald eine die Linie durchbricht.")
                .type(15).foregroundStyle(Palette.inkSoft).frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 12) {
                Button {
                    model.editor = .add(query: nil)
                } label: { Text("Wertpapier hinzufügen").type(14, .semibold).padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button {
                    model.openImport()
                } label: { Text("Liste importieren").type(14).padding(.horizontal, 6) }
                    .controlSize(.large)
                Button {
                    model.loadExample()
                } label: { Text("Beispieldepot ansehen").type(14).padding(.horizontal, 6) }
                    .controlSize(.large)
                    .buttonStyle(.borderless)
            }
            Text("Gespeichert wird in \(model.storagePath)").type(12).foregroundStyle(Palette.inkFaint).textSelection(.enabled)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shown while several rows are selected (⌘ or ⇧ click).
struct SelectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.marked.count
        HStack(spacing: 14) {
            Text(n == 1 ? "1 Wert ausgewählt" : "\(n) Werte ausgewählt").type(13, .semibold).foregroundStyle(Palette.ink)
            Button("Alle sichtbaren auswählen") {
                model.selection = nil
                model.marked = Set(model.visibleOrder)
            }
            .buttonStyle(.borderless).type(13)
            Button("Auswahl aufheben") { model.clearMarks() }
                .buttonStyle(.borderless).type(13)
            GroupAssignMenus(ids: model.marked)
            Button(role: .destructive) {
                model.deleteRequest = .positions(model.marked)
            } label: {
                Text("Löschen …").type(13, .semibold).foregroundStyle(Palette.down)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.signal).frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2)).padding(.vertical, 6) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// "Bank" and "Thema" for all selected values at once.
struct GroupAssignMenus: View {
    @Environment(AppModel.self) private var model
    var ids: Set<UUID>
    var inContextMenu = false

    var body: some View {
        let banks = model.depot.banks.sorted { $0.sortIndex < $1.sortIndex }
        let themes = model.depot.themes.sorted { $0.sortIndex < $1.sortIndex }
        Group {
            Menu {
                ForEach(banks) { b in Button(b.name) { model.assignBank(b.id, to: ids) } }
                if !banks.isEmpty { Divider() }
                Button("Ohne Bank") { model.assignBank(nil, to: ids) }
            } label: {
                Text(inContextMenu ? "Bank zuweisen" : "Bank …").type(13)
            }
            Menu {
                ForEach(themes) { t in Button(t.name) { model.assignTheme(t.id, to: ids) } }
                if !themes.isEmpty { Divider() }
                Button("Ohne Thema") { model.assignTheme(nil, to: ids) }
            } label: {
                Text(inContextMenu ? "Thema zuweisen" : "Thema …").type(13)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
