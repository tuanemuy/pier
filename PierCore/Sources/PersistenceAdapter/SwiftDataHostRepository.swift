import Foundation
import PierDomain
import SwiftData

@Model
public final class HostRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var address: String
    public var username: String
    public var keyID: String

    public init(id: String, name: String, address: String, username: String, keyID: String) {
        self.id = id; self.name = name; self.address = address; self.username = username; self.keyID = keyID
    }
}

@ModelActor
public actor SwiftDataHostRepository: HostRepositoryPort {
    public func all() async throws -> [PierDomain.Host] {
        let records = try modelContext.fetch(FetchDescriptor<HostRecord>(sortBy: [SortDescriptor(\.name)]))
        return try records.map {
            try PierDomain.Host.parse(
                id: HostID(rawValue: $0.id),
                name: $0.name,
                address: $0.address,
                username: $0.username,
                keyID: KeyID(rawValue: $0.keyID)
            ).get()
        }
    }

    public func save(_ host: PierDomain.Host) async throws {
        let id = host.id.rawValue
        let descriptor = FetchDescriptor<HostRecord>(predicate: #Predicate { $0.id == id })
        if let record = try modelContext.fetch(descriptor).first {
            record.name = host.name; record.address = host.address; record.username = host.username; record.keyID = host
                .keyID.rawValue
        } else {
            modelContext.insert(HostRecord(
                id: id,
                name: host.name,
                address: host.address,
                username: host.username,
                keyID: host.keyID.rawValue
            ))
        }
        try modelContext.save()
    }

    public func remove(id: HostID) async throws {
        let rawID = id.rawValue
        try modelContext.delete(model: HostRecord.self, where: #Predicate { $0.id == rawID })
        try modelContext.save()
    }
}

public enum PersistenceFactory {
    public static func live() throws -> SwiftDataHostRepository {
        try SwiftDataHostRepository(modelContainer: ModelContainer(for: HostRecord.self))
    }
}
