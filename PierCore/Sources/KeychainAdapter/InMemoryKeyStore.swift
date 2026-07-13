import Foundation
import PierDomain
import PierSupport

public actor InMemoryKeyStore: KeyStorePort {
    private var keys: [KeyID: SSHKeyMetadata] = [:]
    public init() {}
    public func all() async throws -> [SSHKeyMetadata] {
        Array(keys.values)
    }

    public func generate(name: String, kind: SSHKeyKind) async throws -> SSHKeyMetadata {
        let id = KeyID(rawValue: UUID().uuidString)
        let prefix = kind == .ed25519 ? "ssh-ed25519" : "ecdsa-sha2-nistp256"
        let key = SSHKeyMetadata(id: id, name: name, kind: kind, publicKey: "\(prefix) PREVIEW")
        keys[id] = key; return key
    }

    public func rename(id: KeyID, name: String) async throws {
        guard let key = keys[id] else { throw PierError.authentication("Unknown key") }
        keys[id] = SSHKeyMetadata(id: id, name: name, kind: key.kind, publicKey: key.publicKey)
    }

    public func sign(_ data: sending [UInt8], using keyID: KeyID) async throws -> [UInt8] {
        guard keys[keyID] != nil else { throw PierError.authentication("Unknown key") }
        return data
    }

    public func signingCapability(using keyID: KeyID) async throws -> SSHSigningCapability {
        guard let key = keys[keyID] else { throw PierError.authentication("Unknown key") }
        return SSHSigningCapability(kind: key.kind, publicKey: key.publicKey) { $0 }
    }

    public func remove(id: KeyID) async throws {
        keys.removeValue(forKey: id)
    }
}
