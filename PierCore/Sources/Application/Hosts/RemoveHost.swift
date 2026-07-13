import PierDomain

public struct RemoveHost: Sendable {
    private let repository: any HostRepositoryPort

    public init(repository: any HostRepositoryPort) {
        self.repository = repository
    }

    public func callAsFunction(id: HostID) async throws {
        try await repository.remove(id: id)
    }
}
