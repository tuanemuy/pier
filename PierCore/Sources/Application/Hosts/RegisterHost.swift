import PierDomain

public struct RegisterHost: Sendable {
    private let repository: any HostRepositoryPort
    public init(repository: any HostRepositoryPort) {
        self.repository = repository
    }

    public func callAsFunction(_ host: Host) async throws {
        try await repository.save(host)
    }
}
