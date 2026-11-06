import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    case unexpectedStatus(OSStatus)

    public var description: String {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain 操作失败 (\(status)): \(message)"
        }
    }
}

/// 敏感项存储（文档 §6.7 末段：kSecClassGenericPassword，service = bundle id，account = translate.apiKey）。
/// 实现里永不打印存储内容，错误信息也不带明文。
public protocol SecretStoring: AnyObject {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func removeSecret(for account: String) throws
}

public final class KeychainStore: SecretStoring {
    public static let apiKeyAccount = "translate.apiKey"

    public let service: String

    public init(service: String = Store.keychainService) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func apiKey() throws -> String? {
        try secret(for: Self.apiKeyAccount)
    }

    public func setAPIKey(_ value: String) throws {
        try setSecret(value, for: Self.apiKeyAccount)
    }

    public func removeAPIKey() throws {
        try removeSecret(for: Self.apiKeyAccount)
    }
}
