import Foundation
import PierApplication
import PierDomain
import PierSupport

public actor FileCommandJournal: CommandJournalPort {
    private enum BlockRecordStatus: String, Codable {
        case running
        case finished
    }

    private struct FileRecord: Codable {
        let entries: [Entry]
    }

    private struct Entry: Codable {
        let address: String
        let username: String
        let paneID: String
        var blocks: [BlockRecord]

        func matches(_ key: CommandJournalKey) -> Bool {
            address == key.address && username == key.username && paneID == key.paneID.rawValue
        }
    }

    private struct BlockRecord: Codable {
        let id: UUID
        let command: String
        let output: String
        let startedAt: Date
        let durationMilliseconds: Int64?
        let status: BlockRecordStatus
        let exitCode: Int?

        init(_ block: CommandBlock) throws {
            id = block.id
            command = block.command
            output = block.output
            startedAt = block.startedAt
            durationMilliseconds = block.duration.map(Self.milliseconds)
            switch block.status {
            case .running:
                status = .running
                exitCode = nil
            case let .finished(code):
                status = .finished
                exitCode = code
            case .restored:
                throw PierError.persistence("Restored snapshots cannot be written to the command journal")
            }
        }

        func block() throws -> CommandBlock {
            let commandStatus: CommandStatus
            switch status {
            case .running:
                commandStatus = .running
            case .finished:
                guard let exitCode else { throw PierError.persistence("Finished journal block has no exit code") }
                commandStatus = .finished(exitCode: exitCode)
            }
            return CommandBlock(
                id: id,
                command: command,
                output: output,
                startedAt: startedAt,
                duration: durationMilliseconds.map(Duration.milliseconds),
                status: commandStatus
            )
        }

        private static func milliseconds(_ duration: Duration) -> Int64 {
            let components = duration.components
            return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        }
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load(for key: CommandJournalKey) async throws -> [CommandBlock] {
        do {
            let entries = try readEntries()
            return try entries.first(where: { $0.matches(key) })?.blocks.map { try $0.block() } ?? []
        } catch let error as PierError {
            throw error
        } catch {
            throw PierError.persistence(error.localizedDescription)
        }
    }

    public func save(_ blocks: [CommandBlock], for key: CommandJournalKey) async throws {
        do {
            var entries = try readEntries()
            let entry = try Entry(
                address: key.address,
                username: key.username,
                paneID: key.paneID.rawValue,
                blocks: blocks.map(BlockRecord.init)
            )
            if let index = entries.firstIndex(where: { $0.matches(key) }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
            try write(entries)
        } catch let error as PierError {
            throw error
        } catch {
            throw PierError.persistence(error.localizedDescription)
        }
    }

    public func remove(for key: CommandJournalKey) async throws {
        do {
            var entries = try readEntries()
            entries.removeAll { $0.matches(key) }
            try write(entries)
        } catch {
            throw PierError.persistence(error.localizedDescription)
        }
    }

    private func readEntries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(FileRecord.self, from: Data(contentsOf: fileURL)).entries
    }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(FileRecord(entries: entries)).write(to: fileURL, options: .atomic)
    }
}
