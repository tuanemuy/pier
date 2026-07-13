import Foundation
import PierSupport
import Security

public actor KnownHostStore {
    private let service: String
    public init(service: String = "app.pier.known-hosts") {
        self.service = service
    }

    public func verify(host: String, key: Data) throws -> Bool {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host,
            kSecReturnData: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let saved = result as? Data { return saved == key }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        let addStatus = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: key
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        return true
    }

    private func keychainError(_ status: OSStatus) -> PierError {
        .authentication((SecCopyErrorMessageString(status, nil) as String?) ?? "Known-host Keychain error \(status)")
    }
}
