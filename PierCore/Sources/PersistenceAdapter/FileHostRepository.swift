import Foundation
import PierDomain
import PierSupport

public actor FileHostRepository: HostRepositoryPort {
    private struct Record: Codable {
        let id: String; let name: String; let address: String; let username: String; let keyID: String
    }

    private let fileURL: URL
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func all() async throws -> [PierDomain.Host] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: fileURL))
            return try records.map { record in
                try PierDomain.Host.parse(
                    id: HostID(rawValue: record.id),
                    name: record.name,
                    address: record.address,
                    username: record.username,
                    keyID: KeyID(rawValue: record.keyID)
                ).get()
            }
        } catch { throw PierError.persistence(error.localizedDescription) }
    }

    public func save(_ host: PierDomain.Host) async throws {
        var hosts = try await all().filter { $0.id != host.id }; hosts.append(host)
        try persist(hosts)
    }

    public func remove(id: HostID) async throws {
        try await persist(all().filter { $0.id != id })
    }

    private func persist(_ hosts: [PierDomain.Host]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let records = hosts.map { Record(
                id: $0.id.rawValue,
                name: $0.name,
                address: $0.address,
                username: $0.username,
                keyID: $0.keyID.rawValue
            ) }
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch { throw PierError.persistence(error.localizedDescription) }
    }
}

public actor InMemoryHostRepository: HostRepositoryPort {
    private var hosts: [PierDomain.Host]
    public init(hosts: [PierDomain.Host] = []) {
        self.hosts = hosts
    }

    public func all() async throws -> [PierDomain.Host] {
        hosts
    }

    public func save(_ host: PierDomain.Host) async throws {
        hosts.removeAll { $0.id == host.id }; hosts.append(host)
    }

    public func remove(id: HostID) async throws {
        hosts.removeAll { $0.id == id }
    }
}
