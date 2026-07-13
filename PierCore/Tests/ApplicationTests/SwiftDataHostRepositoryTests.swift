import PersistenceAdapter
import PierDomain
import SwiftData
import XCTest

final class SwiftDataHostRepositoryTests: XCTestCase {
    func testPersistsAndRemovesHost() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: HostRecord.self, configurations: configuration)
        let repository = SwiftDataHostRepository(modelContainer: container)
        let host = try PierDomain.Host.parse(
            id: HostID(rawValue: "host-1"),
            name: "Development",
            address: "dev.example.com",
            username: "pier",
            keyID: KeyID(rawValue: "key-1")
        ).get()

        try await repository.save(host)
        let saved = try await repository.all()
        XCTAssertEqual(saved, [host])
        try await repository.remove(id: host.id)
        let removed = try await repository.all()
        XCTAssertEqual(removed, [])
    }
}
