import Foundation
import UserNotifications

struct NotificationAccess: Equatable, Sendable {
    enum Authorization: Equatable, Sendable { case unknown, notDetermined, denied, allowed }
    var authorization: Authorization
    var banners = true
    var canDeliver: Bool { authorization == .allowed }
    static let unknown = Self(authorization: .unknown)
}

struct NotificationPermissionClient: Sendable {
    var read: @Sendable () async -> NotificationAccess
    var request: @Sendable () async throws -> Bool
    var test: @Sendable () async throws -> Void

    static let live = Self(read: {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorization: NotificationAccess.Authorization
        switch settings.authorizationStatus {
        case .authorized, .provisional: authorization = .allowed
        case .denied: authorization = .denied
        case .notDetermined: authorization = .notDetermined
        @unknown default: authorization = .unknown
        }
        return NotificationAccess(authorization: authorization, banners: settings.alertSetting == .enabled)
    }, request: {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }, test: {
        let content = UNMutableNotificationContent()
        content.title = "Ai-llowance notifications are working"
        content.body = "Your allowance and reset reminders will appear here."
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "allowance-test", content: content, trigger: nil))
    })
}
