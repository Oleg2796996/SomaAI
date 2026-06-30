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
        } else if status != errSecSuccess {
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

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.invalidStatus(status)
        }

        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
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
}
