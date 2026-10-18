import Foundation
import Security

/// Passwords and OAuth tokens, in the login keychain only — never in the app's files or
/// preferences. One generic password per account and kind, under the service `app.void.mail`.
/// The app is signed with an Apple Development certificate (as Void), not ad hoc: macOS then
/// recognizes it from one build to the next and doesn't ask for the session password again.
enum Keychain {
    enum Kind: String {
        case password
        case oauth
    }

    static let service = "app.void.mail"

    #if DEBUG
    /// Debug launches never touch the real keychain.
    nonisolated(unsafe) static var memory: [String: Data]? = DebugLaunch.isRequested ? [:] : nil
    #endif

    static func save(_ data: Data, for account: UUID, kind: Kind) throws {
        let key = "\(account.uuidString).\(kind.rawValue)"
        #if DEBUG
        if memory != nil { memory?[key] = data; return }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Void Mail"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func read(for account: UUID, kind: Kind) -> Data? {
        let key = "\(account.uuidString).\(kind.rawValue)"
        #if DEBUG
        if let memory { return memory[key] }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(for account: UUID) {
        for kind in [Kind.password, .oauth] {
            let key = "\(account.uuidString).\(kind.rawValue)"
            #if DEBUG
            if memory != nil { memory?[key] = nil; continue }
            #endif
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: key]
            SecItemDelete(query as CFDictionary)
        }
    }

    static func savePassword(_ password: String, for account: UUID) throws {
        try save(Data(password.utf8), for: account, kind: .password)
    }

    static func password(for account: UUID) -> String? {
        read(for: account, kind: .password).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "erreur \(status)"
        return "Le trousseau a refusé d'enregistrer le mot de passe (\(message))."
    }
}
