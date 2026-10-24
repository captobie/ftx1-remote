import Foundation
import Security
import os

private let keychainLogger = Logger(subsystem: "com.ftx1remote.mac", category: "logbook")

/// The Wavelog API v2 token (`wl2_…`), kept in the login keychain as a
/// generic password (user decision, over UserDefaults: it grants write
/// access to the log).
/// The app isn't sandboxed, so this is the file-based keychain; Debug and
/// Release builds are signed differently, and each may be asked once to
/// allow access to an item the other created.
enum WavelogToken {
    private static let service = "com.ftx1remote.mac.wavelog"
    private static let account = "api-token"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Empty when none is stored.
    static func read() -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                keychainLogger.error("Reading the Wavelog API token failed: \(status)")
            }
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores `key`; an empty one removes the item.
    static func write(_ key: String) {
        guard !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                keychainLogger.error("Removing the Wavelog API token failed: \(status)")
            }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "FTX1Remote Wavelog API token"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            keychainLogger.error("Storing the Wavelog API token failed: \(status)")
        }
    }
}
