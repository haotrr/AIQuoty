import Foundation

/// Secret material never enters UserDefaults / source / plaintext logs.
public protocol CredentialStore: Sendable {
    func getSecret(account: String) throws -> String?
    func setSecret(_ value: String?, account: String) throws
    func deleteSecret(account: String) throws
}

public enum CredentialAccount {
    public static let claudeOAuthOverride = "claude.oauth.access_token"
    public static let cursorSessionCookie = "cursor.session.cookie"
    public static let cursorBearer = "cursor.session.bearer"
    public static let copilotGitHubToken = "copilot.github.token"
    public static let openRouterAPIKey = "openrouter.api_key"
    public static let anthropicAdminKey = "anthropic.admin_api_key"
    public static let geminiOAuthOverride = "gemini.oauth.access_token"
}

/// In-memory store for tests and Linux CLI. macOS app uses KeychainCredentialStore.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func getSecret(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func setSecret(_ value: String?, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let value {
            storage[account] = value
        } else {
            storage.removeValue(forKey: account)
        }
    }

    public func deleteSecret(account: String) throws {
        try setSecret(nil, account: account)
    }
}

#if os(macOS)
import Security

public struct KeychainCredentialStore: CredentialStore {
    public var service: String

    public init(service: String = "studio.coursion.aistats.AIQuoty") {
        // Bundle-style reverse DNS without claiming a public domain registration.
        self.service = service
    }

    public func getSecret(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderError.network("Keychain 读取失败：\(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, account: String) throws {
        if value == nil {
            try deleteSecret(account: account)
            return
        }
        guard let data = value?.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ProviderError.network("Keychain 写入失败：\(addStatus)")
            }
        } else if status != errSecSuccess {
            throw ProviderError.network("Keychain 更新失败：\(status)")
        }
    }

    public func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ProviderError.network("Keychain 删除失败：\(status)")
        }
    }
}
#endif
