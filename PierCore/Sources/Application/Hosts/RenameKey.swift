import PierDomain

public struct RenameKey: Sendable {
    private let keyStore: any KeyStorePort

    public init(keyStore: any KeyStorePort) {
        self.keyStore = keyStore
    }

    public func callAsFunction(id: KeyID, name: String) async throws {
        try await keyStore.rename(id: id, name: name)
    }
}
