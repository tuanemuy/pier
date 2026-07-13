import PierDomain

public struct ListKeys: Sendable {
    private let keyStore: any KeyStorePort

    public init(keyStore: any KeyStorePort) {
        self.keyStore = keyStore
    }

    public func callAsFunction() async throws -> [SSHKeyMetadata] {
        try await keyStore.all()
    }
}
