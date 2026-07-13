import PierDomain

public struct GenerateKey: Sendable {
    private let keyStore: any KeyStorePort
    public init(keyStore: any KeyStorePort) {
        self.keyStore = keyStore
    }

    public func callAsFunction(name: String, kind: SSHKeyKind) async throws -> SSHKeyMetadata {
        try await keyStore.generate(name: name, kind: kind)
    }
}
