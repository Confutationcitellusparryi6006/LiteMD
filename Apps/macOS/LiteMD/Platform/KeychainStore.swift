import Foundation
import Security

/// 钥匙串中的通用密码项。只保存机密（例如 S3 Secret Access Key），其他设置仍在 UserDefaults。
struct KeychainStore: Sendable {
    let service: String

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 只查询属性，不读取内容，因此不会触发钥匙串授权提示。
    func contains(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// 写入；值为空时删除该项。
    @discardableResult
    func write(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "LiteMD Backup"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
