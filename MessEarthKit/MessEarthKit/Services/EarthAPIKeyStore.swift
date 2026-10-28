import Foundation
import Security

/// Reads only the example app's dedicated login-Keychain credential. The host
/// owns credential persistence; the reusable package receives an in-memory key.
actor EarthAPIKeyStore
{
    func load() throws -> String?
    {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.jvclabs.MessEarthKit.MapTiles",
            kSecAttrAccount as String: "default",
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { throw EarthCredentialError.keychainReadFailed(status) }
        return key
    }
}

enum EarthCredentialError: Error, LocalizedError
{
    case keychainReadFailed(OSStatus)

    var errorDescription: String?
    {
        switch self
        {
            case let .keychainReadFailed(status): "The saved Map Tiles key could not be read from Keychain (\(status)). Enter the key in the secure field or allow this app access in Keychain."
        }
    }
}
