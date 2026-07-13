import Foundation
import PierApplication
import PierDomain
import PierSupport

actor FakeTransport: TransportPort {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var backlog: [Data] = []
    private var streamFinished = false
    private var streamError: PierError?
    private(set) var sent: [String] = []
    private(set) var connections: [(SSHEndpoint, String)] = []
    private(set) var executedCommands: [String] = []
    private(set) var idempotentCommands: [String] = []
    private var remainingConnectionFailures: Int
    private let executionOutput: Data
    private let startupChunks: [Data]
    private let suspendsConnections: Bool
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendNextConnection = false
    private var additionalConnectionFailures = 0
    private var additionalStartupStreamFailures = 0
    private var suspendNextDisconnect = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var transportGeneration: UInt64 = 0
    private var suspendNextSend = false
    private var sendStalled = false
    private var sendEntered: CheckedContinuation<Void, Never>?
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var remainingSendFailures = 0
    init(
        connectionFailures: Int = 0,
        executionOutput: Data = Data(),
        startupChunks: [String] = ["%begin 1 0 0\n%end 1 0 0\n"],
        suspendsConnections: Bool = false
    ) {
        remainingConnectionFailures = connectionFailures
        self.executionOutput = executionOutput
        self.startupChunks = startupChunks.map { Data($0.utf8) }
        self.suspendsConnections = suspendsConnections
    }

    func execute(_ command: String, at _: SSHEndpoint) async throws -> Data {
        executedCommands.append(command)
        return executionOutput
    }

    func executeIdempotent(_ command: String, at _: SSHEndpoint) async throws -> Data {
        idempotentCommands.append(command)
        return executionOutput
    }

    func connect(to endpoint: SSHEndpoint, command: String) async throws -> TransportConnectionGeneration {
        connections.append((endpoint, command))
        if remainingConnectionFailures > 0 || additionalConnectionFailures > 0 {
            if remainingConnectionFailures > 0 {
                remainingConnectionFailures -= 1
            } else {
                additionalConnectionFailures -= 1
            }
            throw PierError.transport("temporary")
        }
        if suspendsConnections || suspendNextConnection {
            suspendNextConnection = false
            await withCheckedContinuation { connectionWaiters.append($0) }
        }
        continuation?.finish()
        continuation = nil
        streamFinished = false
        streamError = nil
        transportGeneration &+= 1
        if additionalStartupStreamFailures > 0 {
            additionalStartupStreamFailures -= 1
            streamFinished = true
            streamError = .transport("startup stream lost")
            return TransportConnectionGeneration(rawValue: transportGeneration)
        }
        for chunk in startupChunks {
            yield(chunk)
        }
        return TransportConnectionGeneration(rawValue: transportGeneration)
    }

    func send(_ data: sending Data, generation: TransportConnectionGeneration) async throws {
        if suspendNextSend {
            suspendNextSend = false
            sendStalled = true
            sendEntered?.resume()
            sendEntered = nil
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        guard generation.rawValue == transportGeneration else { throw PierError.transport("Stale fake writer") }
        if remainingSendFailures > 0 {
            remainingSendFailures -= 1
            throw PierError.transport("send failed")
        }
        guard let command = String(data: data, encoding: .utf8) else {
            throw PierError.invalidResponse("Fake command contains invalid UTF-8")
        }
        sent.append(command)
    }

    func incomingBytes(
        generation: TransportConnectionGeneration
    ) async -> AsyncThrowingStream<Data, Error> {
        guard generation.rawValue == transportGeneration else {
            return AsyncThrowingStream { $0.finish(throwing: PierError.transport("Stale fake reader")) }
        }
        guard continuation == nil else {
            return AsyncThrowingStream { $0.finish(throwing: PierError.unavailable("Fake reader already subscribed")) }
        }
        return AsyncThrowingStream {
            continuation = $0
            for data in backlog {
                $0.yield(data)
            }
            backlog.removeAll()
            if streamFinished {
                if let streamError { $0.finish(throwing: streamError) } else { $0.finish() }
                continuation = nil
            }
        }
    }

    func disconnect() async {
        if suspendNextDisconnect {
            suspendNextDisconnect = false
            await withCheckedContinuation { disconnectWaiters.append($0) }
        }
        continuation?.finish(); continuation = nil
        transportGeneration &+= 1
        resumeConnections()
    }

    func yield(_ text: String) {
        yield(Data(text.utf8))
    }

    func finish(throwing error: PierError? = nil) {
        streamFinished = true
        streamError = error
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil
    }

    func resumeConnections() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func suspendFollowingConnection() {
        suspendNextConnection = true
    }

    func failFollowingConnections(_ count: Int) {
        additionalConnectionFailures = count
    }

    func failFollowingStartupStreams(_ count: Int) {
        additionalStartupStreamFailures = count
    }

    func suspendFollowingDisconnect() {
        suspendNextDisconnect = true
    }

    func resumeDisconnects() {
        let waiters = disconnectWaiters
        disconnectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func stallFollowingSend() {
        suspendNextSend = true
    }

    func waitUntilSendStalled() async {
        if sendStalled { return }
        await withCheckedContinuation { sendEntered = $0 }
    }

    func resumeSends() {
        sendStalled = false
        let waiters = sendWaiters
        sendWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func failFollowingSends(_ count: Int) {
        remainingSendFailures = count
    }

    func yield(_ data: Data) {
        if let continuation { continuation.yield(data) } else { backlog.append(data) }
    }
}

actor FakeRenderer: PaneRendererPort {
    private(set) var output: [PaneID: Data] = [:]
    private(set) var removed: [PaneID] = []
    private var generation: TmuxConnectionGeneration?

    func activate(generation: TmuxConnectionGeneration) {
        guard self.generation == nil || generation.rawValue >= self.generation?.rawValue ?? 0 else { return }
        self.generation = generation
    }

    func feed(_ data: sending Data, to paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == self.generation else { return }
        output[paneID, default: Data()].append(data)
    }

    func reset(paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == self.generation else { return }
        output[paneID] = Data()
    }

    func remove(paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == self.generation else { return }
        output.removeValue(forKey: paneID)
        removed.append(paneID)
    }
}

struct ImmediateClock: Clock {
    func now() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    func sleep(for duration: Duration) async throws {
        if duration.components.seconds > 0 {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

struct FixedIdentifierGenerator: IdentifierGenerator {
    let value: UUID

    init(value: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))) {
        self.value = value
    }

    func makeUUID() -> UUID {
        value
    }
}
