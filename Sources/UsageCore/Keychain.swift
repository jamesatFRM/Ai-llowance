import Foundation
import Security
import LocalAuthentication

public struct KeychainStore: Sendable {
    public let service: String
    public init(service: String = "com.usagebar.credentials") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    public func save(_ secret: String, for id: UUID) throws {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secret.contains("\n"), !secret.contains("\r") else { throw UsageError.missingCredential }
        let value = Data(secret.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            attributes[kSecValueData as String] = value
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw UsageError.storage }
        } else if status != errSecSuccess { throw UsageError.storage }
    }
    public func read(_ id: UUID) throws -> String {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background polling must not trigger a stream of Keychain dialogs.
        let context = LAContext()
        context.interactionNotAllowed = true
        attributes[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { throw UsageError.missingCredential }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw UsageError.storage }
        return value
    }
    public func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UsageError.storage }
    }
}
