import CryptoKit
import Foundation
import PierDomain
import PierSupport
import Security

struct StoredSSHKey: Codable {
    let name: String
    let kind: SSHKeyKind?
    let representation: Data
}

struct KeychainKeyRow {
    let account: String?
    let data: Data?
}

struct KeychainKeyRowDecoder {
    func decode(_ row: KeychainKeyRow, index: Int) throws -> (KeyID, StoredSSHKey) {
        guard let account = row.account, !account.isEmpty, let data = row.data else {
            throw PierError.authentication("Malformed Keychain key row at index \(index)")
        }
        do {
            return try (KeyID(rawValue: account), JSONDecoder().decode(StoredSSHKey.self, from: data))
        } catch {
            throw PierError.authentication("Malformed Keychain key row at index \(index)")
        }
    }
}

public actor SecureEnclaveKeyStore: KeyStorePort {
    private let service: String
    private let rowDecoder: KeychainKeyRowDecoder
    public init(service: String = "app.pier.ssh") {
        self.service = service
        rowDecoder = KeychainKeyRowDecoder()
    }

    init(service: String, rowDecoder: KeychainKeyRowDecoder) {
        self.service = service
        self.rowDecoder = rowDecoder
    }

    public func all() async throws -> [SSHKeyMetadata] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { throw keychainError(status) }
        return try items.enumerated().map { index, item in
            let (id, stored) = try rowDecoder.decode(
                KeychainKeyRow(account: item[kSecAttrAccount] as? String, data: item[kSecValueData] as? Data),
                index: index
            )
            let kind = stored.kind ?? .secureEnclaveP256
            return try SSHKeyMetadata(
                id: id,
                name: stored.name,
                kind: kind,
                publicKey: publicKey(kind: kind, representation: stored.representation)
            )
        }
    }

    public func generate(name: String, kind: SSHKeyKind) async throws -> SSHKeyMetadata {
        let id = KeyID(rawValue: UUID().uuidString.lowercased())
        let representation: Data = switch kind {
        case .secureEnclaveP256:
            try makeSecureEnclaveKey().dataRepresentation
        case .ed25519:
            Curve25519.Signing.PrivateKey().rawRepresentation
        }
        let stored = StoredSSHKey(name: name, kind: kind, representation: representation)
        let status = try SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.rawValue,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: JSONEncoder().encode(stored)
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
        return try SSHKeyMetadata(
            id: id,
            name: name,
            kind: kind,
            publicKey: publicKey(kind: kind, representation: representation)
        )
    }

    public func rename(id: KeyID, name: String) async throws {
        let stored = try storedKey(id: id)
        let updated = StoredSSHKey(name: name, kind: stored.kind, representation: stored.representation)
        let status = try SecItemUpdate([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.rawValue
        ] as CFDictionary, [
            kSecValueData: JSONEncoder().encode(updated)
        ] as CFDictionary)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    public func sign(_ data: sending [UInt8], using keyID: KeyID) async throws -> [UInt8] {
        try await signingCapability(using: keyID).sign(data)
    }

    public func signingCapability(using keyID: KeyID) async throws -> SSHSigningCapability {
        let stored = try storedKey(id: keyID)
        let kind = stored.kind ?? .secureEnclaveP256
        let publicKey = try publicKey(kind: kind, representation: stored.representation)
        switch kind {
        case .secureEnclaveP256:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.representation)
            return SSHSigningCapability(kind: kind, publicKey: publicKey) { data in
                try [UInt8](key.signature(for: data).derRepresentation)
            }
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.representation)
            return SSHSigningCapability(kind: kind, publicKey: publicKey) { data in
                try [UInt8](key.signature(for: data))
            }
        }
    }

    public func remove(id: KeyID) async throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.rawValue
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private func makeSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else {
            throw PierError.authentication(
                accessError?.takeRetainedValue().localizedDescription ?? "Secure Enclave access control failed"
            )
        }
        return try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false,
            accessControl: access,
            authenticationContext: nil
        )
    }

    private func storedKey(id: KeyID) throws -> StoredSSHKey {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.rawValue,
            kSecReturnData: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(StoredSSHKey.self, from: data)
    }

    private func publicKey(kind: SSHKeyKind, representation: Data) throws -> String {
        switch kind {
        case .secureEnclaveP256:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation)
            return openSSHP256PublicKey(key.publicKey.x963Representation)
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: representation)
            return openSSHEd25519PublicKey(key.publicKey.rawRepresentation)
        }
    }

    private func openSSHP256PublicKey(_ point: Data) -> String {
        let algorithm = Data("ecdsa-sha2-nistp256".utf8)
        let curve = Data("nistp256".utf8)
        let blob = sshField(algorithm) + sshField(curve) + sshField(point)
        return "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) pier"
    }

    private func openSSHEd25519PublicKey(_ publicKey: Data) -> String {
        let algorithm = Data("ssh-ed25519".utf8)
        let blob = sshField(algorithm) + sshField(publicKey)
        return "ssh-ed25519 \(blob.base64EncodedString()) pier"
    }

    private func sshField(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data
    }

    private func keychainError(_ status: OSStatus) -> PierError {
        .authentication((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
    }
}
