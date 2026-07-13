import PierDomain

enum WorkspacePreparation: Equatable {
    case idle
    case discovering
    case loaded(host: Host, sessions: [String])
    case failed(message: String)
}

struct WorkspacePreparationMachine: Equatable {
    private(set) var state: WorkspacePreparation = .idle
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        state = .discovering
        return generation
    }

    @discardableResult
    mutating func complete(host: Host, sessions: [String], generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        state = .loaded(host: host, sessions: sessions)
        return true
    }

    @discardableResult
    mutating func fail(message: String, generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        state = .failed(message: message)
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        state = .idle
    }
}

enum RemoteFileEditorState: Equatable {
    case loading
    case loaded(file: RemoteFile, draft: String, saveFailure: String?)
    case saving(file: RemoteFile, draft: String)
    case failed(message: String)

    mutating func beginLoading() {
        self = .loading
    }

    mutating func load(_ file: RemoteFile) {
        self = .loaded(file: file, draft: file.contents, saveFailure: nil)
    }

    mutating func failLoading(message: String) {
        self = .failed(message: message)
    }

    mutating func updateDraft(_ draft: String) {
        guard case let .loaded(file, _, saveFailure) = self else { return }
        self = .loaded(file: file, draft: draft, saveFailure: saveFailure)
    }

    mutating func beginSaving(file: RemoteFile, draft: String) {
        self = .saving(file: file, draft: draft)
    }

    mutating func failSaving(message: String) {
        guard case let .saving(file, draft) = self else { return }
        self = .loaded(file: file, draft: draft, saveFailure: message)
    }

    mutating func clearSaveFailure() {
        guard case let .loaded(file, draft, _) = self else { return }
        self = .loaded(file: file, draft: draft, saveFailure: nil)
    }
}

enum HostListState: Equatable {
    case loading
    case loaded(hosts: [Host], keys: [SSHKeyMetadata])
    case failed(message: String)
}

struct HostListStateMachine: Equatable {
    private(set) var state: HostListState = .loading
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        state = .loading
        return generation
    }

    @discardableResult
    mutating func complete(hosts: [Host], keys: [SSHKeyMetadata], generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        state = .loaded(hosts: hosts, keys: keys)
        return true
    }

    @discardableResult
    mutating func fail(message: String, generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        state = .failed(message: message)
        return true
    }
}

enum KeyManagerState: Equatable {
    case loading
    case loaded([SSHKeyMetadata])
    case failed(message: String)
}

struct KeyManagerStateMachine: Equatable {
    private(set) var state: KeyManagerState = .loading
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        state = .loading
        return generation
    }

    @discardableResult
    mutating func complete(keys: [SSHKeyMetadata], generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        state = .loaded(keys)
        return true
    }

    @discardableResult
    mutating func fail(message: String, generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        state = .failed(message: message)
        return true
    }
}
