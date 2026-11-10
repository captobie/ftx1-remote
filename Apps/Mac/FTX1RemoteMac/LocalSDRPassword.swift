import Foundation
import Security
import os

private let keychainLogger = Logger(subsystem: "com.ftx1remote.mac", category: "kiwisdr")

/// The Local SDR window's KiwiSDR user password, in the login keychain as
/// a generic password (service "FTX1Remote-KiwiSDR", account "kiwi") — the
/// same pattern as `WavelogToken`. One password, whichever host is in the
/// window. Never logged.
enum LocalSDRPassword {
    private static let service = "FTX1Remote-KiwiSDR"
    private static let account = "kiwi"

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
                keychainLogger.error("Reading the KiwiSDR password failed: \(status)")
            }
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores `password`; an empty one removes the item.
    static func write(_ password: String) {
        guard !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                keychainLogger.error("Removing the KiwiSDR password failed: \(status)")
            }
            return
        }
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "FTX1Remote KiwiSDR password"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            keychainLogger.error("Storing the KiwiSDR password failed: \(status)")
        }
    }
}
