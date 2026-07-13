import Foundation

public struct Host: Identifiable, Equatable, Sendable {
    public let id: HostID
    public let name: String
    public let address: String
    public let username: String
    public let keyID: KeyID

    private init(id: HostID, name: String, address: String, username: String, keyID: KeyID) {
        self.id = id; self.name = name; self.address = address; self.username = username; self.keyID = keyID
    }

    public static func parse(
        id: HostID,
        name: String,
        address: String,
        username: String,
        keyID: KeyID
    ) -> Result<Self, HostError> {
        let values = [name, address, username].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty }) else { return .failure(.missingRequiredField) }
        guard !values[1].contains(where: \.isWhitespace) else { return .failure(.invalidAddress) }
        return .success(Self(id: id, name: values[0], address: values[1], username: values[2], keyID: keyID))
    }
}

public enum HostError: Error, Equatable, Sendable { case missingRequiredField, invalidAddress }

public enum SSHKeyKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case secureEnclaveP256
    case ed25519

    public var id: Self {
        self
    }

    public var displayName: String {
        switch self {
        case .secureEnclaveP256: "ECDSA P-256"
        case .ed25519: "Ed25519"
        }
    }

    public var storageName: String {
        switch self {
        case .secureEnclaveP256: "Secure Enclave"
        case .ed25519: "Keychain"
        }
    }

    public var storageSystemImage: String {
        switch self {
        case .secureEnclaveP256: "lock.shield"
        case .ed25519: "key.fill"
        }
    }
}

public struct SSHKeyMetadata: Identifiable, Equatable, Sendable {
    public let id: KeyID
    public let name: String
    public let kind: SSHKeyKind
    public let publicKey: String
    public init(id: KeyID, name: String, kind: SSHKeyKind, publicKey: String) {
        self.id = id; self.name = name; self.kind = kind; self.publicKey = publicKey
    }
}
