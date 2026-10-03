import AppKit
import UserNotifications

/// NSObject subclass required for UNUserNotificationCenterDelegate conformance —
/// Apple's notification delegate protocol inherits from NSObjectProtocol.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onNotificationTapped: ((String, UUID?) -> Void)?

    /// UNUserNotificationCenter.current() crashes when running via `swift run`
    /// (no app bundle → bundleProxyForCurrentProcess is nil). Guard with bundle check.
    private let center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        Task {
            try? await center?.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func postMessageNotification(from senderName: String, body: String, jidString: String, accountID: UUID?, avatarData: Data?) {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = body
        content.sound = .default
        var userInfo: [String: String] = ["jid": jidString]
        if let accountID {
            userInfo["accountID"] = accountID.uuidString
        }
        content.userInfo = userInfo

        if let avatarData {
            attachAvatar(avatarData, to: content)
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center?.add(request)
    }

    func updateDockBadge(totalUnread: Int) {
        NSApp.dockTile.badgeLabel = totalUnread > 0 ? "\(totalUnread)" : nil
    }

    /// Bounces the Dock icon once. Does nothing while the app is active.
    func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let jid = userInfo["jid"] as? String
        let accountID = (userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if let jid {
                onNotificationTapped?(jid, accountID)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Private

    private func attachAvatar(_ data: Data, to content: UNMutableNotificationContent) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try data.write(to: tempURL)
            let attachment = try UNNotificationAttachment(identifier: "avatar", url: tempURL)
            content.attachments = [attachment]
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            // Avatar attachment failed — notification still works without it.
        }
    }
}
