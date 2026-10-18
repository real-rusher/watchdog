import Foundation
import AppKit
import UserNotifications
import ServiceManagement
import CoreImage
import CoreImage.CIFilterBuiltins
import WatchdogCore

/// Banners on the Mac. Clicking one selects the position.
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpen: ((UUID) -> Void)?
    private(set) var authorized: Bool?

    override init() {
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func requestAuthorization(_ done: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            self.authorized = ok
            DispatchQueue.main.async { done?(ok) }
        }
    }

    func status(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    func post(_ events: [SignalEvent]) {
        for e in events {
            let c = UNMutableNotificationContent()
            c.title = e.title
            c.body = e.body
            c.sound = e.severity == .alarm ? .default : nil
            c.threadIdentifier = e.positionID.uuidString
            c.userInfo = ["position": e.positionID.uuidString]
            if #available(macOS 12.0, *) {
                c.interruptionLevel = e.severity == .alarm ? .timeSensitive : .active
            }
            let req = UNNotificationRequest(identifier: e.id, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    func postTest() {
        let c = UNMutableNotificationContent()
        c.title = "Watchdog"
        c.body = "Test: So sieht eine Mitteilung aus."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["position"] as? String, let id = UUID(uuidString: s) {
            onOpen?(id)
        }
        completionHandler()
    }
}

/// Start at login via the system's login items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum QRCode {
    static func image(for text: String, size: CGFloat = 220) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
