import Foundation
@testable import PierApplication
import PierDomain
import PierSupport
import XCTest

final class DiscoverSessionsTests: XCTestCase {
    private let endpoint = SSHEndpoint(address: "host", username: "user", keyID: KeyID(rawValue: "key"))

    func testReturnsExistingSessionNames() async throws {
        let transport = FakeTransport(executionOutput: Data("main\ndevelopment\n".utf8))

        let sessions = try await DiscoverSessions()(transport: transport, endpoint: endpoint)

        XCTAssertEqual(sessions, ["main", "development"])
        let commands = await transport.idempotentCommands
        XCTAssertEqual(commands.count, 1)
    }

    func testReportsMissingTmux() async throws {
        let transport = FakeTransport(executionOutput: Data("__PIER_TMUX_MISSING__\n".utf8))

        do {
            _ = try await DiscoverSessions()(transport: transport, endpoint: endpoint)
            XCTFail("Expected missing tmux error")
        } catch let error as PierError {
            XCTAssertEqual(
                error,
                .unavailable("接続先にtmuxがインストールされていません。tmuxをインストールしてから再試行してください。")
            )
        }
    }

    func testCreatesDefaultSessionWhenNoneExist() async throws {
        let transport = FakeTransport()

        let sessions = try await DiscoverSessions()(transport: transport, endpoint: endpoint)

        XCTAssertEqual(sessions, ["main"])
        let commands = await transport.idempotentCommands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(
            commands.last,
            "tmux has-session -t '=main' 2>/dev/null || " +
                "tmux new-session -d -s main 2>/dev/null || tmux has-session -t '=main'"
        )
        XCTAssertFalse(commands.last?.contains("new-session -A") == true)
        let ambiguousCommands = await transport.executedCommands
        XCTAssertTrue(ambiguousCommands.isEmpty)
    }

    func testDefaultSessionCreationIsSafeWhenResponseIsLostAndRetried() async throws {
        let transport = ResponseLossRetryTransport()

        let sessions = try await DiscoverSessions()(transport: transport, endpoint: endpoint)

        XCTAssertEqual(sessions, ["main"])
        let state = await transport.state
        XCTAssertEqual(state.attempts, 2)
        XCTAssertEqual(state.creationCount, 1)
        XCTAssertTrue(state.sessionExists)
    }

    func testConcurrentDefaultSessionCreatorsConvergeOnSingleSession() async throws {
        let transport = ConcurrentCreationTransport()
        let endpoint = endpoint

        async let first = DiscoverSessions()(transport: transport, endpoint: endpoint)
        async let second = DiscoverSessions()(transport: transport, endpoint: endpoint)
        let results = try await [first, second]

        XCTAssertEqual(results, [["main"], ["main"]])
        let state = await transport.state
        XCTAssertEqual(state.ensureAttempts, 2)
        XCTAssertEqual(state.creationCount, 1)
        XCTAssertEqual(state.duplicateCreationFailures, 1)
        XCTAssertEqual(state.finalExistenceChecks, 1)
        XCTAssertTrue(state.sessionExists)
    }
}

private actor ResponseLossRetryTransport: TransportPort {
    private(set) var state = (attempts: 0, creationCount: 0, sessionExists: false)
    private var responseFailures = 1

    func execute(_: String, at _: SSHEndpoint) async throws -> Data {
        XCTFail("Discovery must use the idempotent execution path")
        return Data()
    }

    func executeIdempotent(_ command: String, at _: SSHEndpoint) async throws -> Data {
        guard command == DiscoverSessions.ensureDefaultSessionCommand else { return Data() }
        for _ in 1 ... 2 {
            do {
                return try performRemoteCommand()
            } catch ResponseError.lostAfterRemoteSuccess {
                continue
            }
        }
        throw PierError.transport("unreachable")
    }

    private func performRemoteCommand() throws -> Data {
        state.attempts += 1
        if !state.sessionExists {
            state.sessionExists = true
            state.creationCount += 1
        }
        if responseFailures > 0 {
            responseFailures -= 1
            throw ResponseError.lostAfterRemoteSuccess
        }
        return Data()
    }

    func connect(to _: SSHEndpoint, command _: String) async throws -> TransportConnectionGeneration {
        throw PierError.unavailable("unused")
    }

    func send(_: sending Data, generation _: TransportConnectionGeneration) async throws {}

    func incomingBytes(generation _: TransportConnectionGeneration) async -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func disconnect() async {}

    private enum ResponseError: Error {
        case lostAfterRemoteSuccess
    }
}

private actor ConcurrentCreationTransport: TransportPort {
    private(set) var state = (
        ensureAttempts: 0,
        creationCount: 0,
        duplicateCreationFailures: 0,
        finalExistenceChecks: 0,
        sessionExists: false
    )
    private var creators: [CheckedContinuation<Void, Never>] = []

    func execute(_: String, at _: SSHEndpoint) async throws -> Data {
        XCTFail("Discovery must use the idempotent execution path")
        return Data()
    }

    func executeIdempotent(_ command: String, at _: SSHEndpoint) async throws -> Data {
        guard command == DiscoverSessions.ensureDefaultSessionCommand else { return Data() }
        state.ensureAttempts += 1
        let existedAtInitialCheck = state.sessionExists
        guard !existedAtInitialCheck else { return Data() }
        await synchronizeCreators()
        if !state.sessionExists {
            state.sessionExists = true
            state.creationCount += 1
        } else {
            state.duplicateCreationFailures += 1
            state.finalExistenceChecks += 1
            guard state.sessionExists else { throw PierError.transport("default session creation failed") }
        }
        return Data()
    }

    private func synchronizeCreators() async {
        await withCheckedContinuation { continuation in
            creators.append(continuation)
            guard creators.count == 2 else { return }
            let ready = creators
            creators.removeAll()
            ready.forEach { $0.resume() }
        }
    }

    func connect(to _: SSHEndpoint, command _: String) async throws -> TransportConnectionGeneration {
        throw PierError.unavailable("unused")
    }

    func send(_: sending Data, generation _: TransportConnectionGeneration) async throws {}

    func incomingBytes(generation _: TransportConnectionGeneration) async -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func disconnect() async {}
}
