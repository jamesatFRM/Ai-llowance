import AppKit
import Foundation
import UserNotifications

/// A remembered user-selected executable is accepted only while its resolved file is unchanged.
struct RememberedExecutable: Codable {
    let path: String
    let size: UInt64
    let modified: Date
    let inode: UInt64
    init?(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolved.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        self.path = resolved.path; self.size = size.uint64Value; self.modified = modified; self.inode = inode.uint64Value
    }
    var validatedURL: URL? {
        let url = URL(fileURLWithPath: path)
        guard let current = RememberedExecutable(url: url), current.path == path,
              current.size == size, current.modified == modified, current.inode == inode else { return nil }
        return url
    }
}

struct BrowserProfile: Identifiable, Equatable {
    let id: String
    let name: String
    static func discover() -> [BrowserProfile] {
        let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let handle = try? FileHandle(forReadingFrom: state) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_001), data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any],
              let profiles = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        return profiles.compactMap { id, value in
            guard id == "Default" || (id.hasPrefix("Profile ") && id.dropFirst(8).allSatisfy(\.isNumber)),
                  let name = value["name"] as? String else { return nil }
            return BrowserProfile(id: id, name: "Chrome · " + String(name.prefix(80)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

final class AllowanceNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let open: @MainActor @Sendable (UUID?) -> Void
    init(open: @escaping @MainActor @Sendable (UUID?) -> Void) { self.open = open }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in open(id) }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
