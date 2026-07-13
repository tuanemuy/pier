import PierDomain

public struct ListHosts: Sendable {
    private let repository: any HostRepositoryPort

    public init(repository: any HostRepositoryPort) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> [Host] {
        try await repository.all()
    }
}
