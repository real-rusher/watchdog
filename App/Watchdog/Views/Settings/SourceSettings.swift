import SwiftUI
import WatchdogCore

struct SourceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reihenfolge der Datenquellen").type(15, .semibold).foregroundStyle(Palette.ink)
            Text("Watchdog fragt für jeden Wert die erste Quelle, die dessen Börse kennt. Antwortet sie nicht oder drosselt, wird automatisch die nächste genommen. Zum Umsortieren ziehen.")
                .type(12).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            Toggle("Bei Fehlern automatisch auf die nächste Quelle wechseln", isOn: Binding(get: { model.depot.sources.autoFallback },
                                                                                       set: { v in model.mutate { $0.sources.autoFallback = v } }))
            List {
                ForEach(model.depot.sources.order) { p in
                    SourceRow(provider: p)
                }
                .onMove { from, to in
                    model.mutate { $0.sources.order.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button("Standardreihenfolge") { model.mutate { $0.sources.order = ProviderID.defaultOrder } }
                Button("Fehlerstatus zurücksetzen") { Task { await model.engine.router.health.reset(); await model.recompute() } }
                Spacer()
                Button("Jetzt alle Kurse neu laden") { model.refresh(force: true) }
            }
        }
        .padding(20)
    }
}

private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    @State private var key = ""

    var body: some View {
        let enabled = !model.depot.sources.disabled.contains(provider)
        let status = model.snapshot?.health[provider]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(Palette.inkFaint)
                Toggle("", isOn: Binding(get: { enabled }, set: { v in
                    model.mutate { if v { $0.sources.disabled.remove(provider) } else { $0.sources.disabled.insert(provider) } }
                })).labelsHidden()
                Text(provider.displayName).type(14, .semibold).foregroundStyle(enabled ? Palette.ink : Palette.inkFaint)
                if model.depot.sources.primary == provider { Tag(text: "zuerst") }
                Spacer()
                statusView(status)
            }
            Text(provider.summary).type(12).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            if provider.requiresKey {
                HStack {
                    SecureField("API-Schlüssel", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit { saveKey() }
                    Button("Sichern") { saveKey() }.disabled(key == (model.local.apiKeys[provider.rawValue] ?? ""))
                    if let url = provider.signupURL { Link("Kostenlosen Schlüssel holen", destination: url).type(12) }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { key = model.local.apiKeys[provider.rawValue] ?? "" }
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateLocal { $0.apiKeys[provider.rawValue] = k.isEmpty ? nil : k }
    }

    @ViewBuilder
    private func statusView(_ s: ProviderHealth.Status?) -> some View {
        if let s {
            if let until = s.cooldownUntil, until > Date() {
                Text("pausiert bis \(Format.time(until))").type(11, .medium).foregroundStyle(Palette.caution).help(s.lastError ?? "")
            } else if s.successCount > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(s.successCount) Abrufe ok" + (s.failureCount > 0 ? ", \(s.failureCount) Fehler" : "")).type(11).foregroundStyle(Palette.inkSoft)
                    if let t = s.lastSuccess { Text("zuletzt \(Format.time(t))").type(11).foregroundStyle(Palette.inkFaint) }
                }
                .help(s.lastError ?? "")
            } else if s.failureCount > 0 {
                Text("\(s.failureCount) Fehler").type(11, .medium).foregroundStyle(Palette.down).help(s.lastError ?? "")
            }
        } else if provider.requiresKey && model.local.keys[provider] == nil {
            Text("ohne Schlüssel inaktiv").type(11).foregroundStyle(Palette.inkFaint)
        }
    }
}

struct ExchangeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Exchange?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Börsen im Auswahlmenü").type(15, .semibold).foregroundStyle(Palette.ink)
            Text("Aktive Börsen erscheinen beim Hinzufügen zuerst. Je Börse lässt sich festlegen, welche Datenquelle zuerst gefragt wird.")
                .type(12).foregroundStyle(Palette.inkSoft)
            List {
                ForEach(model.catalog.all) { e in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { e.isActive }, set: { v in
                            var x = e; x.isActive = v
                            model.mutate { $0.upsertExchange(x) }
                        })).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name).type(13, .medium).foregroundStyle(e.isActive ? Palette.ink : Palette.inkSoft)
                            Text("\(e.currency), \(e.hoursText)").type(11).foregroundStyle(Palette.inkFaint)
                        }
                        .frame(width: 210, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(ProviderID.defaultOrder.filter { e.supports($0) }) { p in
                                Text(p.shortName).type(10, .semibold).foregroundStyle(Palette.inkSoft)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.rule))
                                    .help(p.displayName)
                            }
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { model.depot.sources.perExchange[e.id]?.first }, set: { (v: ProviderID?) in
                            model.mutate { d in
                                if let v {
                                    var order = d.sources.order
                                    order.removeAll { $0 == v }
                                    order.insert(v, at: 0)
                                    d.sources.perExchange[e.id] = order
                                } else {
                                    d.sources.perExchange[e.id] = nil
                                }
                            }
                        })) {
                            Text("Quelle automatisch").tag(ProviderID?.none)
                            ForEach(ProviderID.defaultOrder.filter { e.supports($0) }) { p in Text("Zuerst \(p.displayName)").tag(ProviderID?.some(p)) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        Button { editing = e } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("Bearbeiten")
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button("Eigene Börse hinzufügen …") { creating = true }
                Spacer()
            }
        }
        .padding(20)
        .sheet(item: $editing) { e in ExchangeEditor(exchange: e).environment(model) }
        .sheet(isPresented: $creating) {
            ExchangeEditor(exchange: Exchange(id: "C\(Int.random(in: 1000...9999))", name: "", badge: "", country: "", currency: "EUR",
                                              timeZone: "Europe/Berlin", opens: 9 * 60, closes: 17 * 60 + 30, codes: [:], isCustom: true))
                .environment(model)
        }
    }
}

private struct ExchangeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var exchange: Exchange
    @State private var opens = ""
    @State private var closes = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Börse") {
                    TextField("Name", text: $exchange.name)
                    TextField("Kurzname (max. 6 Zeichen)", text: $exchange.badge)
                    TextField("Währung (ISO, z. B. EUR, USD, JPY)", text: $exchange.currency)
                    TextField("Zeitzone (z. B. Europe/Berlin)", text: $exchange.timeZone)
                    HStack {
                        TextField("Öffnet (HH:MM)", text: $opens)
                        TextField("Schließt (HH:MM)", text: $closes)
                    }
                }
                Section("Kürzel bei den Datenquellen") {
                    ForEach(ProviderID.defaultOrder) { p in
                        TextField(p.displayName, text: Binding(get: { exchange.codes[p.rawValue] ?? "" }, set: { v in
                            let t = v.trimmingCharacters(in: .whitespaces)
                            exchange.codes[p.rawValue] = t.isEmpty ? nil : t
                        }), prompt: Text(hint(p)))
                    }
                    Text("Beispiele: Yahoo-Endung \u{201E}.DE\u{201C}, OnVista-Marktcode \u{201E}_GAT\u{201C}, FT-Börsencode \u{201E}TYO\u{201C}. Leer bedeutet: diese Quelle wird für die Börse nicht benutzt.")
                        .type(11).foregroundStyle(Palette.inkSoft)
                }
            }
            .formStyle(.grouped)
            HStack {
                if !exchange.isCustom {
                    Button("Auf Standard zurücksetzen") {
                        model.mutate { $0.exchanges.removeAll { $0.id == exchange.id } }
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    exchange.opens = Self.minutes(opens) ?? exchange.opens
                    exchange.closes = Self.minutes(closes) ?? exchange.closes
                    exchange.currency = exchange.currency.uppercased()
                    if exchange.badge.isEmpty { exchange.badge = String(exchange.name.prefix(5)) }
                    model.mutate { $0.upsertExchange(exchange) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exchange.name.isEmpty || TimeZone(identifier: exchange.timeZone) == nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            opens = String(format: "%02d:%02d", exchange.opens / 60, exchange.opens % 60)
            closes = String(format: "%02d:%02d", exchange.closes / 60, exchange.closes % 60)
        }
    }

    private func hint(_ p: ProviderID) -> String {
        switch p {
        case .yahoo: return "Endung, z. B. .DE"
        case .onvista: return "Marktcode, z. B. _GAT"
        case .ft: return "Börsencode, z. B. GER"
        case .eodhd: return "z. B. XETRA"
        case .twelvedata: return "MIC, z. B. XETR"
        case .alphavantage: return "Endung ohne Punkt, z. B. DEX"
        case .finnhub: return "Endung, z. B. .DE"
        case .lstc: return "1"
        case .tradegate: return "TG"
        case .bitfinex: return "BFX"
        }
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}
