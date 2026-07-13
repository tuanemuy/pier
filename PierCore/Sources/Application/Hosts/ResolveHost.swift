import PierDomain

public struct ResolveHost: Sendable {
    private let repository: any HostRepositoryPort

    public init(repository: any HostRepositoryPort) {
        self.repository = repository
    }

    public func callAsFunction(id: HostID) async throws -> Host? {
        try await repository.all().first { $0.id == id }
    }
}
