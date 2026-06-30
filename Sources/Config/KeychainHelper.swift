import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case duplicateItem
    case invalidStatus(OSStatus)
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "API key not found. Please set it in Settings."
        case .duplicateItem:
            return "API key already exists."
        case .invalidStatus(let status):
            return "Keychain error: \(status)"
        case .conversionFailed:
            return "Could not convert API key data."
        }
    }
}

/// Sprint 4.7e: multi-provider API key storage.
/// `accountName` distinguishes Wormsoft / OpenAI / custom endpoints.
/// Default "default" preserves backward compatibility with pre-4.7e code.
struct KeychainHelper {
    static let shared = KeychainHelper()
    private let service = Bundle.main.bundleIdentifier ?? "com.olegkonovalov.SomaAI"

    init() {
        print("[SomaAI] KeychainHelper.init: service=\(service)")
    }

    func save(_ value: String, accountName: String = "default") throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.conversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountName,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Update existing item
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: accountName,
                kSecAttrService as String: service
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.invalidStatus(updateStatus)
            }
            print("[SomaAI] KeychainHelper.save: updated account=\(accountName), value.length=\(value.count)")
        } else if status == errSecSuccess {
            print("[SomaAI] KeychainHelper.save: created account=\(accountName), value.length=\(value.count)")
        } else {
            print("[SomaAI] KeychainHelper.save: FAILED account=\(accountName), status=\(status)")
            throw KeychainError.invalidStatus(status)
        }
    }

    func read(accountName: String = "default") throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountName,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            print("[SomaAI] KeychainHelper.read: OK account=\(accountName)")
        } else if status == errSecItemNotFound {
            print("[SomaAI] KeychainHelper.read: NOT_FOUND account=\(accountName)")
        } else {
            print("[SomaAI] KeychainHelper.read: FAILED account=\(accountName), status=\(status)")
        }

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.invalidStatus(status)
        }

        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            print("[SomaAI] KeychainHelper.read: CONVERSION_FAILED account=\(accountName)")
            throw KeychainError.conversionFailed
        }

        return value
    }

    func delete(accountName: String = "default") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountName,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.invalidStatus(status)
        }
    }

    /// Returns first 7 + last 4 chars for safe display in Settings UI.
    /// Never returns the full key. Useful for "is the key I just pasted
    /// the same one I think it is?" UX.
    func masked(accountName: String = "default") -> String {
        guard let full = try? read(accountName: accountName), full.count >= 12 else {
            return "not set"
        }
        let prefix = full.prefix(7)
        let suffix = full.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    /// Sprint 4.7g: auto-migrate old 'default' Wormsoft key into the new
    /// 'soma_api_key_wormsoft' account. Run once on app launch.
    /// Returns true if migration happened, false otherwise.
    @discardableResult
    func migrateLegacyDefaultAccount() -> Bool {
        // Check if old 'default' key exists
        guard let oldKey = try? read(accountName: "default"), !oldKey.isEmpty else {
            return false  // nothing to migrate
        }
        // Check if new account is empty
        if (try? read(accountName: APIProvider.wormsoft.keychainAccount)) != nil {
            print("[SomaAI] Keychain migration skipped: new account already has a key")
            // Old key still exists but new one is set — leave both, user can clean up
            return false
        }
        // Migrate
        do {
            try save(oldKey, accountName: APIProvider.wormsoft.keychainAccount)
            try delete(accountName: "default")
            print("[SomaAI] Keychain migration: 'default' → 'soma_api_key_wormsoft' done")
            return true
        } catch {
            print("[SomaAI] KeyChain migration FAILED: \(error.localizedDescription)")
            return false
        }
    }
}
