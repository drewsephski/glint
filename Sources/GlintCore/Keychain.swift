import Foundation
import Security

/// The signing identity of the running binary. A Team ID means a stable identity (Developer ID), which is what makes
/// Keychain items usable across updates without prompts.
public enum CodeIdentity {
    public static let teamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var sc: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let sc else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let team = d[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }()
}

public enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    public var description: String {
        switch self { case .status(let s): return "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")" }
    }
}

/// Generic-password items in the user's login keychain.
enum Keychain {
    static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func get(service: String, account: String) -> String? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(service: String, account: String, value: String?) throws {
        let q = query(service, account)
        guard let value else {
            let s = SecItemDelete(q as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError.status(s) }
            return
        }
        let data = Data(value.utf8)
        var s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Glint API key (\(account))"
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw KeychainError.status(s) }
    }
}
