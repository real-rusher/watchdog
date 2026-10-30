import SwiftUI
import UIKit
import WatchdogCore

/// Banks (one per depot) and themes (uranium, oil, gold ...): add, rename, colour, reorder, delete.
struct GroupsView: View {
    @Environment(MobileModel.self) private var model
    @State private var newBank = ""
    @State private var newTheme = ""

    var body: some View {
        List {
            Section {
                ForEach(model.banks) { b in
                    NameRow(name: b.name) { model.renameBank(b.id, $0) }
                }
                .onDelete { idx in model.deleteBanks(idx.map { model.banks[$0].id }) }
                .onMove { model.moveBanks(from: $0, to: $1) }
                HStack {
                    TextField("Neue Bank", text: $newBank).submitLabel(.done).onSubmit(addBank)
                    Button("Hinzufügen", action: addBank).disabled(newBank.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Banken")
            } footer: {
                Text("Werte einer gelöschten Bank bleiben erhalten und stehen dann unter \u{201E}Ohne Bank\u{201C}.")
            }
            Section {
                ForEach(model.themes) { t in
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { Color(hexString: t.color) ?? Palette.inkSoft },
                            set: { model.recolorTheme(t.id, Self.hex($0)) }), supportsOpacity: false)
                            .labelsHidden()
                        NameRow(name: t.name) { model.renameTheme(t.id, $0) }
                    }
                }
                .onDelete { idx in model.deleteThemes(idx.map { model.themes[$0].id }) }
                .onMove { model.moveThemes(from: $0, to: $1) }
                HStack {
                    TextField("Neues Thema", text: $newTheme).submitLabel(.done).onSubmit(addTheme)
                    Button("Hinzufügen", action: addTheme).disabled(newTheme.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Themen")
            } footer: {
                Text("Zum Umsortieren oben auf \u{201E}Bearbeiten\u{201C} tippen. Werte eines gelöschten Themas bleiben erhalten.")
            }
        }
        .navigationTitle("Banken und Themen")
        .toolbar { EditButton() }
    }

    private func addBank() {
        model.addBank(newBank)
        newBank = ""
    }

    private func addTheme() {
        model.addTheme(newTheme)
        newTheme = ""
    }

    static func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ v: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }
}

/// A name that is saved when typing ends (return or leaving the field), not on every key press.
private struct NameRow: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, f in if !f { commit(text) } }
            .onAppear { text = name }
            .onChange(of: name) { _, n in if !focused { text = n } }
    }
}
