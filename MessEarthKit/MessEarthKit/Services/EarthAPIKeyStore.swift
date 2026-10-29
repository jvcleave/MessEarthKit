import Foundation
import Security

/// The app's dedicated login-Keychain credential never enters project metadata.
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

    func save(_ key: String) throws
    {
        guard !key.isEmpty else { throw EarthCredentialError.emptyKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.jvclabs.MessEarthKit.MapTiles",
            kSecAttrAccount as String: "default",
            kSecUseDataProtectionKeychain as String: false,
        ]
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound
        {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EarthCredentialError.keychainWriteFailed(status) }
    }
}

enum EarthCredentialError: Error, LocalizedError
{
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case emptyKey

    var errorDescription: String?
    {
        switch self
        {
            case let .keychainReadFailed(status): "The saved Map Tiles key could not be read from Keychain (\(status)). Enter the key in the secure field or allow this app access in Keychain."
            case let .keychainWriteFailed(status): "The Map Tiles key could not be saved to Keychain (\(status))."
            case .emptyKey: "Enter an API key before saving it."
        }
    }
}
