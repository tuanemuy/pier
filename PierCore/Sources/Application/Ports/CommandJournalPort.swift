import PierDomain

public struct CommandJournalKey: Hashable, Sendable {
    public let address: String
    public let username: String
    public let paneID: PaneID

    public init(address: String, username: String, paneID: PaneID) {
        self.address = address
        self.username = username
        self.paneID = paneID
    }
}

public protocol CommandJournalPort: Sendable {
    func load(for key: CommandJournalKey) async throws -> [CommandBlock]
    func save(_ blocks: [CommandBlock], for key: CommandJournalKey) async throws
    func remove(for key: CommandJournalKey) async throws
}

public actor InMemoryCommandJournal: CommandJournalPort {
    private var storage: [CommandJournalKey: [CommandBlock]]

    public init(storage: [CommandJournalKey: [CommandBlock]] = [:]) {
        self.storage = storage
    }

    public func load(for key: CommandJournalKey) -> [CommandBlock] {
        storage[key, default: []]
    }

    public func save(_ blocks: [CommandBlock], for key: CommandJournalKey) {
        storage[key] = blocks
    }

    public func remove(for key: CommandJournalKey) {
        storage.removeValue(forKey: key)
    }
}

public struct NullCommandJournal: CommandJournalPort {
    public init() {}
    public func load(for _: CommandJournalKey) async throws -> [CommandBlock] {
        []
    }

    public func save(_: [CommandBlock], for _: CommandJournalKey) async throws {}
    public func remove(for _: CommandJournalKey) async throws {}
}
