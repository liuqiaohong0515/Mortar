import Foundation
import LocalAuthentication
import Security

enum KeychainStore {
    private static let service = "com.lqh.Mortar.svn"

    static func save(account: String, secret: String) {
        delete(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let access = unlockedAccess() {
            query[kSecAttrAccess as String] = access
        }
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    static func allAccounts() -> [String: String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: silentContext(),
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let rows = item as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String, let secret = load(account: account) else { continue }
            result[account] = secret
        }
        return result
    }

    private static func base(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: silentContext(),
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private static func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// The app is ad-hoc signed, so its code hash changes on every build.
    /// A signature-bound login-keychain ACL asks again after each launch.
    /// This access list allows a read without that system prompt.
    private static func unlockedAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("Mortar" as CFString, [] as CFArray, &access) == errSecSuccess, let access else { return nil }
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess, let acls = aclList as? [SecACL] else { return access }
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else { continue }
            SecACLSetContents(acl, nil, description ?? "Mortar" as CFString, [])
        }
        return access
    }
}
