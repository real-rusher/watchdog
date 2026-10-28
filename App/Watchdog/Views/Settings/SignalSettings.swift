import SwiftUI
import WatchdogCore

struct SignalSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editingRule: Rule?

    var body: some View {
        let rules = model.depot.rules
        Form {
            Section {
                LabeledContent("Linie") {
                    LineSpecPicker(spec: Binding(get: { rules.ampel.line }, set: { v in model.mutate { $0.rules.ampel.line = v } }), allowPrice: false)
                }
                HStack {
                    Text("Gelb bei weniger als")
                    Slider(value: Binding(get: { rules.ampel.yellowBandPercent }, set: { v in model.mutate { $0.rules.ampel.yellowBandPercent = (v * 2).rounded() / 2 } }), in: 0...10)
                    Text(Format.pct(rules.ampel.yellowBandPercent)).frame(width: 54, alignment: .trailing).monospacedDigit()
                }
                Picker("Gelbe Zone", selection: Binding(get: { rules.ampel.yellowMode }, set: { v in model.mutate { $0.rules.ampel.yellowMode = v } })) {
                    ForEach(AmpelConfig.YellowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Als \u{201E}frisch gekreuzt\u{201C} markieren: \(rules.ampel.freshDays) Handelstage", value: Binding(get: { rules.ampel.freshDays }, set: { v in model.mutate { $0.rules.ampel.freshDays = v } }), in: 1...30)
                Toggle("Kreuzungen erst mit dem Schlusskurs werten", isOn: Binding(get: { rules.confirmOnClose }, set: { v in model.mutate { $0.rules.confirmOnClose = v } }))
                Text("Aus: Watchdog meldet sofort, wenn der aktuelle Kurs die Linie durchbricht. An: erst wenn der Tag unter bzw. über der Linie schließt, dafür ohne Fehlalarme durch kurze Ausschläge.")
                    .type(12).foregroundStyle(Palette.inkSoft)
            } header: {
                Text("Ampel")
            }

            Section("Linien im Chart") {
                ForEach(Array(rules.chartLines.enumerated()), id: \.offset) { i, spec in
                    HStack {
                        RoundedRectangle(cornerRadius: 1).fill(Palette.line(spec, index: i)).frame(width: 18, height: 4)
                        LineSpecPicker(spec: Binding(get: { spec }, set: { v in model.mutate { $0.rules.chartLines[i] = v } }), allowPrice: false)
                        Spacer()
                        Button(role: .destructive) { model.mutate { $0.rules.chartLines.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(rules.chartLines.count <= 1)
                    }
                }
                Button("Linie hinzufügen") { model.mutate { $0.rules.chartLines.append(.sma(50)) } }
                    .buttonStyle(.borderless)
            }

            Section("Regeln") {
                ForEach(rules.rules) { r in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { r.enabled }, set: { v in update(r.id) { $0.enabled = v } })).labelsHidden()
                        Circle().fill(color(r.severity)).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).type(13, .medium).foregroundStyle(r.enabled ? Palette.ink : Palette.inkFaint)
                            Text(r.condition.summary).type(11).foregroundStyle(Palette.inkSoft)
                        }
                        Spacer()
                        Image(systemName: r.notify ? "bell.fill" : "bell.slash").foregroundStyle(r.notify ? Palette.ink : Palette.inkFaint)
                            .help(r.notify ? "Meldet sich" : "Meldet sich nicht")
                        Button { editingRule = r } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button(role: .destructive) { model.mutate { $0.rules.rules.removeAll { $0.id == r.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Neue Regel …") {
                        editingRule = Rule(name: "Neue Regel", condition: Condition(kind: .crossesBelow, a: .price, b: .sma(100), days: 5), severity: .warning, notify: true)
                    }
                    Button("Standardregeln wiederherstellen") { model.mutate { $0.rules.rules = RuleSet.defaultRules } }
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingRule) { r in
            RuleEditor(rule: r) { saved in
                model.mutate { d in
                    if let i = d.rules.rules.firstIndex(where: { $0.id == saved.id }) { d.rules.rules[i] = saved } else { d.rules.rules.append(saved) }
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Rule) -> Void) {
        model.mutate { d in if let i = d.rules.rules.firstIndex(where: { $0.id == id }) { change(&d.rules.rules[i]) } }
    }

    private func color(_ s: Severity) -> Color {
        switch s {
        case .alarm: return Palette.down
        case .warning: return Palette.caution
        case .info: return Palette.up
        }
    }
}

struct LineSpecPicker: View {
    @Binding var spec: LineSpec
    var allowPrice: Bool

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { spec.kind }, set: { k in spec = LineSpec(k, spec.length == 0 ? 200 : spec.length) })) {
                if allowPrice { Text("Kurs").tag(LineSpec.Kind.price) }
                Text("Gleitender Durchschnitt").tag(LineSpec.Kind.sma)
                Text("Exponentieller Durchschnitt").tag(LineSpec.Kind.ema)
            }
            .labelsHidden()
            .frame(width: 210)
            if spec.kind != .price {
                TextField("", value: Binding(get: { spec.length }, set: { n in spec = LineSpec(spec.kind, max(2, min(400, n))) }), format: .number)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                Text("Tage")
            }
        }
    }
}

private struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    var save: (Rule) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $rule.name)
                Picker("Art", selection: $rule.condition.kind) {
                    ForEach(Condition.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if rule.condition.kind.usesLines {
                    LabeledContent("Was") { LineSpecPicker(spec: $rule.condition.a, allowPrice: true) }
                    LabeledContent(rule.condition.kind.label) { LineSpecPicker(spec: $rule.condition.b, allowPrice: true) }
                }
                if rule.condition.kind.isEvent {
                    Stepper("Innerhalb der letzten \(rule.condition.days) Handelstage", value: $rule.condition.days, in: 1...60)
                }
                if rule.condition.kind == .near {
                    TextField("Abstand höchstens (%)", value: $rule.condition.percent, format: .number)
                }
                if rule.condition.kind == .changeBelow || rule.condition.kind == .changeAbove {
                    Picker("Zeitraum", selection: $rule.condition.period) {
                        ForEach(PerformancePeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Schwelle in % (z. B. -15)", value: $rule.condition.percent, format: .number)
                }
                Picker("Wichtigkeit", selection: $rule.severity) {
                    ForEach(Severity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Mitteilung senden", isOn: $rule.notify)
                Toggle("In der Tabelle anzeigen", isOn: $rule.showBadge)
                Text(rule.condition.summary).type(12).foregroundStyle(Palette.inkSoft)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { save(rule); dismiss() }.keyboardShortcut(.defaultAction).disabled(rule.name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var macStatus = "wird geprüft"
    @State private var testResult: String?
    @State private var heartbeatTesting = false

    var body: some View {
        let n = model.depot.notifications
        let allowed = max(3 * model.local.quoteIntervalMinutes, 45)
        Form {
            Section("Auf dem Mac") {
                Toggle("Mitteilungen anzeigen", isOn: Binding(get: { n.macEnabled }, set: { v in
                    model.mutate { $0.notifications.macEnabled = v }
                    if v { model.notifier.requestAuthorization { _ in refreshStatus() } }
                }))
                LabeledContent("Status", value: macStatus)
                HStack {
                    Button("Test-Mitteilung") { model.notifier.postTest() }
                    Button("Systemeinstellungen öffnen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
            Section("Auf iPhone und Apple Watch (über die App ntfy)") {
                Toggle("Mitteilungen an ntfy senden", isOn: Binding(get: { n.ntfyEnabled }, set: { v in model.mutate { $0.notifications.ntfyEnabled = v } }))
                if n.ntfyEnabled {
                    HStack(alignment: .top, spacing: 18) {
                        if let url = n.subscribeURL, let img = QRCode.image(for: url.absoluteString, size: 150) {
                            Image(nsImage: img).interpolation(.none).resizable().frame(width: 150, height: 150)
                                .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Auf dem iPhone die kostenlose App \u{201E}ntfy\u{201C} aus dem App Store laden.").type(12)
                            Text("2. In ntfy auf \u{201E}+\u{201C} tippen und diesen Kanal abonnieren:").type(12)
                            Text(n.ntfyTopic).type(14, .semibold).textSelection(.enabled)
                            Text("Oder den QR-Code mit der iPhone-Kamera scannen.").type(12)
                            Text("3. Mitteilungen erlauben. Was auf dem iPhone ankommt, erscheint automatisch auch auf der Apple Watch.").type(12)
                        }
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Server", text: Binding(get: { n.ntfyServer }, set: { v in model.mutate { $0.notifications.ntfyServer = v } }))
                    HStack {
                        TextField("Kanal", text: Binding(get: { n.ntfyTopic }, set: { v in model.mutate { $0.notifications.ntfyTopic = v } }))
                        Button("Neuen Kanal erzeugen") { model.mutate { $0.notifications.ntfyTopic = NotificationSettings.randomTopic() } }
                    }
                    Text("Der Kanalname wirkt wie ein Passwort: Wer ihn kennt, kann die Meldungen mitlesen. Die Meldungen enthalten nur Name, Kurs und Signal, keine Stückzahlen oder Beträge.")
                        .type(11).foregroundStyle(Palette.inkSoft)
                    Toggle("Tippen auf die Meldung öffnet den Wert in der Watchdog-App auf dem iPhone",
                           isOn: Binding(get: { n.ntfyOpensApp }, set: { v in model.mutate { $0.notifications.ntfyOpensApp = v } }))
                    Text("Erst einschalten, wenn die Watchdog-App auf dem iPhone installiert ist. Ohne sie kann ntfy den Link nicht öffnen.")
                        .type(11).foregroundStyle(Palette.inkSoft)
                    HStack {
                        Button("Testnachricht senden") {
                            testResult = "wird gesendet …"
                            let s = model.depot.notifications
                            Task {
                                do {
                                    try await model.engine.sendTestPush(s)
                                    testResult = "Gesendet. Sollte in wenigen Sekunden auf dem iPhone erscheinen."
                                } catch {
                                    testResult = "Fehler: \(error)"
                                }
                            }
                        }
                        if let t = testResult { Text(t).type(12).foregroundStyle(Palette.inkSoft) }
                    }
                }
            }
            DevicesSection()
            Section("Wenn Kurse ausbleiben") {
                Toggle("Melden, wenn Kurse ausbleiben", isOn: Binding(get: { n.dataAlerts }, set: { v in model.mutate { $0.notifications.dataAlerts = v } }))
                Text("Kommt während der Handelszeit \(allowed) Minuten lang kein Kurs an, fehlt ein Schlusskurs, endet der Kursverlauf oder fehlt ein Wechselkurs, wird der Wert in der Tabelle sofort markiert. Hält das 20 Minuten an, kommt eine Mitteilung auf dem Mac und über ntfy, höchstens eine am Tag.")
                    .type(11).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Section("Lebenszeichen (freiwillig)") {
                Text("Watchdog kann nur warnen, solange er läuft. Damit auch ein ausgeschalteter oder schlafender Mac auffällt, ruft Watchdog alle 5 Minuten eine Adresse auf. Ein kostenloser Dienst wie healthchecks.io meldet sich über ntfy oder E-Mail, sobald diese Aufrufe ausbleiben.")
                    .type(11).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                TextField("Adresse", text: Binding(get: { n.heartbeatURL ?? "" }, set: { v in
                    model.mutate { $0.notifications.heartbeatURL = v.isEmpty ? nil : v }
                }), prompt: Text("https://hc-ping.com/…"))
                HStack {
                    Button("Jetzt testen") {
                        heartbeatTesting = true
                        Task {
                            await model.heartbeat(force: true)
                            heartbeatTesting = false
                        }
                    }
                    .disabled(n.heartbeat == nil || heartbeatTesting)
                    Text(heartbeatStatus(n)).type(12).foregroundStyle(heartbeatColor(n))
                    Spacer()
                    Link("healthchecks.io", destination: URL(string: "https://healthchecks.io")!).type(12)
                }
                Text("Tipp: Dort als Zeitplan die Handelszeiten eintragen, zum Beispiel Cron \u{201E}*/5 8-22 * * 1-5\u{201C} mit Zeitzone Europe/Berlin und 30 Minuten Kulanz. Dann gibt es nachts und am Wochenende keine Fehlalarme.")
                    .type(11).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Section("Letzte Meldungen") {
                let log = model.snapshot?.eventLog ?? []
                if log.isEmpty {
                    Text("Noch keine Signale ausgelöst.").type(12).foregroundStyle(Palette.inkSoft)
                } else {
                    ForEach(log.prefix(20)) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).type(13, .medium)
                            Text(e.body).type(11).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStatus)
    }

    private func heartbeatStatus(_ n: NotificationSettings) -> String {
        if heartbeatTesting { return "wird gesendet …" }
        if n.heartbeatURL?.isEmpty == false && n.heartbeat == nil { return "Adresse ungültig" }
        guard n.heartbeat != nil else { return "aus" }
        guard let r = model.heartbeatResult else { return "noch nicht gesendet" }
        if let e = r.error { return "Fehler \(Format.time(r.date)): \(e)" }
        return "zuletzt gemeldet \(Format.time(r.date))"
    }

    private func heartbeatColor(_ n: NotificationSettings) -> Color {
        if model.heartbeatResult?.error != nil || (n.heartbeatURL?.isEmpty == false && n.heartbeat == nil) { return Palette.down }
        return Palette.inkSoft
    }

    private func refreshStatus() {
        model.notifier.status { s in
            switch s {
            case .authorized, .provisional: macStatus = "erlaubt"
            case .denied: macStatus = "in den Systemeinstellungen abgeschaltet"
            case .notDetermined: macStatus = "noch nicht gefragt"
            default: macStatus = "unbekannt"
            }
        }
    }
}

/// Which device checks prices and announces: the Mac first, the iPhone when the Mac stops, the Watch when both stop.
private struct DevicesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Mac, iPhone und Apple Watch") {
            Text("Geprüft und gemeldet wird in dieser Reihenfolge: zuerst der Mac. Prüft er 20 Minuten lang nicht (ausgeschaltet, im Ruhezustand, ohne Internet), übernimmt das iPhone, danach die Apple Watch. Was ein Gerät schon gemeldet hat, meldet kein anderes noch einmal. Dazu liegt neben der Depotdatei in iCloud Drive die kleine Datei \u{201E}Mitteilungen.json\u{201C}.")
                .type(12).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            let l = model.ledger
            let duty = l?.onDuty(asking: .mac) ?? .mac
            ForEach(CheckerRole.allCases, id: \.self) { role in
                LabeledContent {
                    Text(status(role, l)).type(12).foregroundStyle(l?.isActive(role) == true ? Palette.ink : Palette.inkSoft)
                } label: {
                    HStack(spacing: 6) {
                        Text(role.displayName).type(13, .medium)
                        if role == duty {
                            Text("meldet").type(11, .semibold).foregroundStyle(Color.black.opacity(0.85))
                                .padding(.horizontal, 5).padding(.vertical, 0.5)
                                .background(Palette.signal, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
        }
        .onAppear { model.reloadLedger() }
    }

    private func status(_ role: CheckerRole, _ l: NotificationLedger?) -> String {
        guard let c = l?.checkers[role] else {
            return role == .mac ? "prüft, sobald die Depotdatei in iCloud Drive liegt" : "noch nicht eingerichtet"
        }
        let when = Format.time(c.lastCheck)
        if l?.isActive(role) == true { return "\(c.device): prüft, zuletzt \(when)" }
        return c.healthy ? "\(c.device): seit \(when) keine Prüfung" : "\(c.device): bekommt seit \(when) kaum Kurse"
    }
}
