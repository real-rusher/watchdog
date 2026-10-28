import Foundation
import WatchConnectivity
import WatchdogCore

/// iPhone side of the connection to the Apple Watch: sends the current reading, receives what the Watch announced.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Events the Watch announced and its last heartbeat, to be written into the shared ledger.
    var onReport: (@Sendable ([String], NotificationLedger.Checker?) -> Void)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isWatchAppInstalled: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }

    /// The Watch keeps only the newest context, so sending after every check is cheap.
    func send(_ snapshot: WatchSnapshot) {
        guard isWatchAppInstalled, let data = try? snapshot.encoded() else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let ids = userInfo["reported"] as? [String] ?? []
        let checker = (userInfo["heartbeat"] as? Data).flatMap { try? DepotStore.decoder().decode(NotificationLedger.Checker.self, from: $0) }
        onReport?(ids, checker)
    }
}
