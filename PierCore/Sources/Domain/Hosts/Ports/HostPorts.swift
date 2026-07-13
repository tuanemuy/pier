public protocol HostRepositoryPort: Sendable {
    func all() async throws -> [Host]
    func save(_ host: Host) async throws
    func remove(id: HostID) async throws
}

public protocol KeyStorePort: Sendable {
    func all() async throws -> [SSHKeyMetadata]
    func generate(name: String, kind: SSHKeyKind) async throws -> SSHKeyMetadata
    func rename(id: KeyID, name: String) async throws
    func sign(_ data: sending [UInt8], using keyID: KeyID) async throws -> [UInt8]
    func signingCapability(using keyID: KeyID) async throws -> SSHSigningCapability
    func remove(id: KeyID) async throws
}

public struct SSHSigningCapability: Sendable {
    public typealias Signer = @Sendable ([UInt8]) throws -> [UInt8]
    public let kind: SSHKeyKind
    public let publicKey: String
    private let signer: Signer

    public init(kind: SSHKeyKind, publicKey: String, signer: @escaping Signer) {
        self.kind = kind
        self.publicKey = publicKey
        self.signer = signer
    }

    public func sign(_ data: [UInt8]) throws -> [UInt8] {
        try signer(data)
    }
}
