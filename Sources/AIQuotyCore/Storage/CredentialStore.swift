import Foundation
#if os(macOS)
import Security
#endif

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
    public static let geminiOAuthBundle = "gemini.oauth.bundle"
    public static let geminiOAuthClientID = "gemini.oauth.client_id"
    public static let geminiOAuthClientSecret = "gemini.oauth.client_secret"
    public static let openCodeAPIKey = "opencode.api_key"
    public static let openCodeSessionCookie = "opencode.session_cookie"
    public static let deepSeekAPIKey = "deepseek.api_key"
    public static let kimiCodeToken = "kimi.code.token"
    public static let moonshotAPIKey = "moonshot.api_key"
    public static let miniMaxAPIKey = "minimax.api_key"
    public static let zaiAPIKey = "zai.api_key"
    public static let factoryAPIKey = "factory.api_key"
    public static let windsurfAPIKey = "windsurf.api_key"
    public static let grokAPIKey = "grok.api_key"
}

/// Reads an existing third-party CLI's macOS Keychain generic password item (read-only).
public protocol ExternalKeychainReading: Sendable {
    func readGenericPassword(service: String, account: String?) -> Data?
}

public extension ExternalKeychainReading {
    func readGenericPassword(service: String) -> Data? {
        readGenericPassword(service: service, account: nil)
    }
}

public struct NullExternalKeychainReader: ExternalKeychainReading {
    public init() {}
    public func readGenericPassword(service: String, account: String?) -> Data? { nil }
}

#if os(macOS)
private final class ExternalKeychainCache: @unchecked Sendable {
    enum Entry {
        case value(Data)
        case denied
    }

    static let shared = ExternalKeychainCache()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func get(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func set(_ key: String, entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = entry
    }
}

public struct MacOSExternalKeychainReader: ExternalKeychainReading {
    public init() {}

    public func readGenericPassword(service: String, account: String?) -> Data? {
        let cacheKey = "\(service)::\(account ?? "")"
        if let cached = ExternalKeychainCache.shared.get(cacheKey) {
            switch cached {
            case .value(let data): return data
            case .denied: return nil
            }
        }
        // First check existence via attributes-only query (never triggers a Keychain password prompt).
        var probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account, !account.isEmpty {
            probe[kSecAttrAccount as String] = account
        }
        var probeItem: CFTypeRef?
        let probeStatus = SecItemCopyMatching(probe as CFDictionary, &probeItem)
        guard probeStatus == errSecSuccess else {
            return nil
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                ExternalKeychainCache.shared.set(cacheKey, entry: .denied)
            }
            return nil
        }
        ExternalKeychainCache.shared.set(cacheKey, entry: .value(data))
        return data
    }
}
#endif

public enum DefaultExternalKeychain {
    public static func make() -> ExternalKeychainReading {
        #if os(macOS)
        return MacOSExternalKeychainReader()
        #else
        return NullExternalKeychainReader()
        #endif
    }
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
private final class KeychainVaultCache: @unchecked Sendable {
    static let shared = KeychainVaultCache()
    private let lock = NSLock()
    private var vaults: [String: [String: String]] = [:]

    func get(service: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return vaults[service]
    }

    func set(service: String, vault: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        vaults[service] = vault
    }
}

/// Consolidated, in-memory cached macOS Keychain store.
/// Stores all AIQuoty secrets in a single `vault.v1` Keychain item so macOS never
/// prompts per-provider or repeatedly on refresh ticks, while transparently migrating
/// any legacy per-account Keychain items once.
public struct KeychainCredentialStore: CredentialStore {
    public var service: String
    private static let vaultAccount = "vault.v1"

    public init(service: String = "studio.coursion.aistats.AIQuoty") {
        // Bundle-style reverse DNS without claiming a public domain registration.
        self.service = service
    }

    public func getSecret(account: String) throws -> String? {
        let vault = try loadOrMigrateVault()
        return vault[account]
    }

    public func setSecret(_ value: String?, account: String) throws {
        var vault = (try? loadOrMigrateVault()) ?? [:]
        if let value, !value.isEmpty {
            vault[account] = value
        } else {
            vault.removeValue(forKey: account)
        }
        try persistVault(vault)
        KeychainVaultCache.shared.set(service: service, vault: vault)
    }

    public func deleteSecret(account: String) throws {
        try setSecret(nil, account: account)
    }

    private func loadOrMigrateVault() throws -> [String: String] {
        if let cached = KeychainVaultCache.shared.get(service: service) {
            return cached
        }
        // 1. Check if consolidated vault.v1 exists (attribute-only probe never prompts).
        if itemExists(account: Self.vaultAccount) {
            do {
                if let raw = try readRawItem(account: Self.vaultAccount),
                   let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                    KeychainVaultCache.shared.set(service: service, vault: decoded)
                    return decoded
                }
            } catch {
                // User denied or Keychain unavailable — cache empty map for this session so we never loop-prompt.
                KeychainVaultCache.shared.set(service: service, vault: [:])
                return [:]
            }
        }

        // 2. Migrate any existing legacy per-account items into vault.v1 once.
        let legacyAccounts = existingLegacyAccounts()
        var migrated: [String: String] = [:]
        for acct in legacyAccounts {
            if let secret = try? readRawItem(account: acct), !secret.isEmpty {
                migrated[acct] = secret
            }
        }
        if !migrated.isEmpty {
            try? persistVault(migrated)
            for acct in legacyAccounts {
                deleteRawItem(account: acct)
            }
        }
        KeychainVaultCache.shared.set(service: service, vault: migrated)
        return migrated
    }

    private func existingLegacyAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0 != Self.vaultAccount }
    }

    private func itemExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    private func readRawItem(account: String) throws -> String? {
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

    private func persistVault(_ vault: [String: String]) throws {
        let data = try JSONEncoder().encode(vault)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.vaultAccount,
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

    private func deleteRawItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
#endif
