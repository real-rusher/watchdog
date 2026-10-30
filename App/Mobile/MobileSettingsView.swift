import SwiftUI
import UIKit
import WatchdogCore

struct MobileSettingsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Depot") {
                    LabeledContent("Ordner", value: model.isDemo ? "Beispieldepot" : (model.folder?.lastPathComponent ?? "nicht gewählt"))
                    LabeledContent("Werte", value: "\(model.depot.positions.count)")
                    if let e = model.depotError { Text(e).foregroundStyle(Palette.down) }
                    NavigationLink("Banken und Themen") { GroupsView() }
                    if !model.isDemo { Button("Anderen Ordner wählen") { picking = true } }
                    Text("Mac und iPhone bearbeiten dasselbe Depot in iCloud Drive. Speichern beide kurz nacheinander, bleiben die Änderungen beider erhalten. Importieren und die übrigen Einstellungen gehen am Mac.")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                }
                Section("Mitteilungen") {
                    LabeledContent("Auf diesem iPhone", value: statusText)
                    if model.notificationStatus == .denied {
                        Button("In den Einstellungen erlauben") {
                            if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                    Text("Der Mac meldet Durchbrüche zuerst. Prüft er 20 Minuten lang nicht, meldet das iPhone, danach die Apple Watch. Was ein Gerät gemeldet hat, meldet kein anderes noch einmal. Im Hintergrund prüft das iPhone, wann iOS es zulässt; das kann alle 15 Minuten sein oder seltener.")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                }
                Section("Wer gerade prüft") {
                    let l = model.ledger
                    let duty = l?.onDuty(asking: .iphone)
                    ForEach(CheckerRole.allCases, id: \.self) { role in
                        LabeledContent {
                            Text(status(role, l)).foregroundStyle(l?.isActive(role) == true ? Palette.ink : Palette.inkSoft)
                        } label: {
                            HStack(spacing: 6) {
                                Text(role.displayName)
                                if role == duty {
                                    Text("meldet").font(.caption.weight(.semibold)).foregroundStyle(Color.black.opacity(0.85))
                                        .padding(.horizontal, 5).background(Palette.signal, in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }
                    }
                }
                Section("Apple Watch") {
                    LabeledContent("Watchdog auf der Watch", value: model.watch.isWatchAppInstalled ? "installiert" : "nicht installiert")
                    Text("Die Watch zeigt die Werte unter der Linie und auf dem Zifferblatt deren Anzahl. Sie bekommt die Daten vom iPhone und prüft nur dann selbst, wenn Mac und iPhone nicht prüfen.")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                }
                Section {
                    Button("Kurse jetzt neu laden") { Task { await model.refresh(force: true) } }
                        .disabled(model.isRefreshing)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
                if case .success(let url) = r { model.chooseFolder(url) }
            }
            .task {
                model.reloadLedger()
                await model.refreshNotificationStatus()
            }
        }
    }

    private var statusText: String {
        switch model.notificationStatus {
        case .authorized, .provisional, .ephemeral: return "erlaubt"
        case .denied: return "nicht erlaubt"
        default: return "noch nicht gefragt"
        }
    }

    private func status(_ role: CheckerRole, _ l: NotificationLedger?) -> String {
        guard let c = l?.checkers[role] else { return "noch nie geprüft" }
        let when = Format.time(c.lastCheck)
        if l?.isActive(role) == true { return "prüft, zuletzt \(when)" }
        return c.healthy ? "seit \(when) still" : "seit \(when) kaum Kurse"
    }
}
