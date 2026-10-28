import SwiftUI
import WatchdogCore

@main
struct WatchdogMobileApp: App {
    @State private var model = MobileModel()
    @Environment(\.scenePhase) private var phase
    private let notifications = NotificationHandler()

    init() {
        Typo.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear {
                    let m = model
                    notifications.open = { id in Task { @MainActor in m.selection = id } }
                    model.start()
                }
                .onOpenURL { model.open($0) }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: model.becameActive()
            case .background: model.scheduleBackgroundCheck()
            default: break
            }
        }
        .backgroundTask(.appRefresh(MobileModel.backgroundTaskID)) {
            await model.backgroundCheck()
        }
    }
}
