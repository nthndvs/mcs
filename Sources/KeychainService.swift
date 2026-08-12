import Foundation
import Security

/// Thin wrapper over macOS Keychain generic-password items.
///
/// All four keys live in a single "vault" item (a small JSON dictionary), so
/// macOS shows at most one keychain permission prompt per app build instead
/// of one prompt per key. The previous app's four separate items are still
/// read once for migration and kept in sync on writes, so the old app keeps
/// working with its existing credentials.
enum KeychainService {
    static let vaultService = "local.model-compare-studio.vault"

    // Previous app's per-key services (read for migration; synced on writes).
    static let zai = "local.model-compare.zai"
    static let tavily = "local.model-compare.tavily"
    static let meta = "local.model-compare.meta"
    static let deepSeek = "local.model-compare.deepseek"

    /// Vault key name → legacy service name.
    private static let legacyServices: [(name: String, service: String)] = [
        ("zai", zai),
        ("tavily", tavily),
        ("meta", meta),
        ("deepseek", deepSeek),
    ]

    // MARK: - Raw item access

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
        ]
    }

    static func loadRaw(service: String) -> String? {
        var query = query(service: service)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveRaw(_ key: String, service: String) -> OSStatus {
        let baseQuery = query(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Update first so replacing a key is atomic. A delete/add sequence can
        // briefly remove a working credential and hides Keychain write errors.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var item = baseQuery
        for (attribute, value) in attributes { item[attribute] = value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus != errSecDuplicateItem { return addStatus }

        // A concurrent Keychain update can create the item between the update
        // and add calls. Retry the update in that rare case.
        return SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    }

    static func delete(service: String) {
        _ = SecItemDelete(query(service: service) as CFDictionary)
    }

    static func errorDescription(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }

    // MARK: - Vault (single item holding all keys)

    /// Loads every stored key with a single Keychain access.
    static func loadAll() -> [String: String] {
        guard let raw = loadRaw(service: vaultService),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict.filter { !$0.value.isEmpty }
    }

    @discardableResult
    static func saveAll(_ keys: [String: String]) -> OSStatus {
        let filtered = keys.filter { !$0.value.isEmpty }
        guard !filtered.isEmpty else {
            delete(service: vaultService)
            return errSecSuccess
        }
        guard let data = try? JSONEncoder().encode(filtered),
              let raw = String(data: data, encoding: .utf8) else { return errSecParam }
        return saveRaw(raw, service: vaultService)
    }

    /// Loads the vault; on first launch migrates the previous app's four
    /// separate items into it. Legacy items are left in place for the old app.
    static func loadAllMigratingLegacy() -> [String: String] {
        let existing = loadAll()
        if !existing.isEmpty { return existing }
        var migrated: [String: String] = [:]
        for (name, service) in legacyServices {
            if let value = loadRaw(service: service), !value.isEmpty {
                migrated[name] = value
            }
        }
        if !migrated.isEmpty { saveAll(migrated) }
        return migrated
    }

    /// Updates one key in the vault and mirrors it to the previous app's
    /// per-key item so both apps stay in sync.
    @discardableResult
    static func setKey(_ name: String, value: String, in keys: inout [String: String]) -> OSStatus {
        if value.isEmpty {
            keys.removeValue(forKey: name)
        } else {
            keys[name] = value
        }
        let status = saveAll(keys)
        if let legacy = legacyServices.first(where: { $0.name == name }) {
            if value.isEmpty {
                delete(service: legacy.service)
            } else {
                saveRaw(value, service: legacy.service)
            }
        }
        return status
    }
}
