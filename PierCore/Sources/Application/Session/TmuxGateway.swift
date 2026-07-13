import Foundation
import PierDomain
import PierSupport

public actor TmuxGateway {
    public enum State: Equatable, Sendable { case disconnected, connecting, connected, reconnecting(attempt: Int) }

    private struct PendingCommand {
        let token: UInt64
        let data: Data
        let continuation: CheckedContinuation<[String], Error>
        var response: [String] = []
        var marker: TmuxTransactionMarker?
        var sent = false
    }

    private struct StartupTransaction {
        let continuation: CheckedContinuation<Void, Error>
        var marker: TmuxTransactionMarker?
        var response: [String] = []
    }

    private let transport: any TransportPort
    private let renderer: any PaneRendererPort
    private let logger: any PierLogger
    private var readTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var transportGeneration: TransportConnectionGeneration?
    private var startup: StartupTransaction?
    private var unsolicitedMarker: TmuxTransactionMarker?
    private var pending: [PendingCommand] = []
    private var subscribers: [UInt64: AsyncStream<TmuxMessage>.Continuation] = [:]
    private var nextToken: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var lineBuffer = Data()
    public private(set) var state: State = .disconnected

    public init(transport: any TransportPort, renderer: any PaneRendererPort, logger: any PierLogger = NullLogger()) {
        self.transport = transport; self.renderer = renderer; self.logger = logger
    }

    deinit { readTask?.cancel() }

    @discardableResult
    public func connect(endpoint: SSHEndpoint, sessionName: String) async throws -> TmuxConnectionGeneration {
        switch state {
        case .disconnected:
            break
        case .connecting, .reconnecting:
            throw TmuxConnectionError.connectionInProgress
        case .connected:
            throw TmuxConnectionError.alreadyConnected
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let rendererGeneration = TmuxConnectionGeneration(rawValue: generation)
        state = .connecting
        lineBuffer.removeAll(keepingCapacity: true)
        unsolicitedMarker = nil
        await renderer.activate(generation: rendererGeneration)
        guard generation == connectionGeneration else { throw TmuxConnectionError.superseded }
        let target = Self.quote(sessionName)
        do {
            let transportGeneration = try await transport.connect(
                to: endpoint,
                command: "tmux -CC new-session -A -s \(target)"
            )
            guard generation == connectionGeneration, state == .connecting else {
                throw TmuxConnectionError.superseded
            }
            self.transportGeneration = transportGeneration
            startReading(generation: generation, transportGeneration: transportGeneration)
            try await waitForStartup()
            guard generation == connectionGeneration, state == .connecting else {
                throw TmuxConnectionError.superseded
            }
            state = .connected
            return TmuxConnectionGeneration(rawValue: generation)
        } catch {
            if generation == connectionGeneration {
                state = .disconnected
                readTask?.cancel()
                readTask = nil
                sendTask?.cancel()
                sendTask = nil
                transportGeneration = nil
                await transport.disconnect()
            }
            throw error
        }
    }

    public func disconnect(if generation: TmuxConnectionGeneration) async {
        guard generation.rawValue == connectionGeneration else { return }
        await disconnect()
    }

    public func disconnect() async {
        connectionGeneration &+= 1
        let rendererGeneration = TmuxConnectionGeneration(rawValue: connectionGeneration)
        state = .disconnected
        readTask?.cancel(); readTask = nil
        sendTask?.cancel(); sendTask = nil
        transportGeneration = nil
        failStartup(PierError.transport("Disconnected"))
        failPending(PierError.transport("Disconnected"))
        unsolicitedMarker = nil
        lineBuffer.removeAll(keepingCapacity: true)
        await renderer.activate(generation: rendererGeneration)
        await transport.disconnect()
    }

    public func messages() -> AsyncStream<TmuxMessage> {
        let token = makeToken()
        return AsyncStream { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(token) } }
        }
    }

    public func command(_ command: String) async throws -> [String] {
        guard state == .connected else { throw PierError.unavailable("No active tmux connection") }
        return try await withCheckedThrowingContinuation { continuation in
            let token = makeToken()
            pending.append(PendingCommand(
                token: token,
                data: Data((command + "\n").utf8),
                continuation: continuation
            ))
            sendNextIfNeeded()
        }
    }

    @discardableResult public func capturePane(_ paneID: PaneID) async throws -> Data {
        let generation = connectionGeneration
        let rendererGeneration = TmuxConnectionGeneration(rawValue: generation)
        let lines = try await command("capture-pane -e -p -S - -t \(paneID.rawValue)")
        guard generation == connectionGeneration else { throw TmuxConnectionError.superseded }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        await renderer.reset(paneID: paneID, generation: rendererGeneration)
        guard generation == connectionGeneration else { throw TmuxConnectionError.superseded }
        await renderer.feed(data, to: paneID, generation: rendererGeneration)
        guard generation == connectionGeneration else { throw TmuxConnectionError.superseded }
        return data
    }

    public func removeRenderedPane(_ paneID: PaneID, generation: TmuxConnectionGeneration) async {
        await renderer.remove(paneID: paneID, generation: generation)
    }

    public func connectedGeneration() throws -> TmuxConnectionGeneration {
        guard state == .connected else { throw TmuxConnectionError.connectionInProgress }
        return TmuxConnectionGeneration(rawValue: connectionGeneration)
    }

    private func startReading(
        generation: UInt64,
        transportGeneration: TransportConnectionGeneration
    ) {
        readTask?.cancel()
        readTask = Task { [weak self, transport] in
            do {
                try Task.checkCancellation()
                let stream = await transport.incomingBytes(generation: transportGeneration)
                try Task.checkCancellation()
                for try await data in stream {
                    await self?.consume(data, generation: generation)
                }
                await self?.connectionEnded(PierError.transport("SSH stream ended"), generation: generation)
            } catch { await self?.connectionEnded(error, generation: generation) }
        }
    }

    private func consume(_ data: Data, generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            guard generation == connectionGeneration else { return }
            let raw = lineBuffer[..<newline]
            lineBuffer.removeSubrange(...newline)
            let lineBytes = raw.last == 13 ? raw.dropLast() : raw[...]
            switch TmuxParser.parse(Data(lineBytes)) {
            case let .success(message):
                await dispatch(message, generation: generation)
                guard generation == connectionGeneration else { return }
            case let .failure(error):
                logger.log(.warning, "Malformed tmux line: \(error)")
                let terminalError: Error = if startup != nil, error == .invalidUTF8 {
                    TmuxStartupError.invalidUTF8
                } else if startup != nil {
                    TmuxStartupError.malformedLine(Self.replacingInvalidUTF8(in: lineBytes))
                } else {
                    error
                }
                await connectionEnded(terminalError, generation: generation)
                return
            }
        }
    }
}

extension TmuxGateway {
    private func dispatch(_ message: TmuxMessage, generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        switch message {
        case let .begin(timestamp, commandNumber, flags):
            await handleBegin(
                .init(timestamp: timestamp, commandNumber: commandNumber, flags: flags),
                generation: generation
            )
        case let .responseLine(line):
            handleResponseLine(line)
        case let .end(timestamp, commandNumber, flags):
            await handleEnd(
                .init(timestamp: timestamp, commandNumber: commandNumber, flags: flags),
                generation: generation
            )
        case let .commandError(timestamp, commandNumber, flags):
            await handleCommandError(
                .init(timestamp: timestamp, commandNumber: commandNumber, flags: flags),
                generation: generation
            )
        case let .output(paneID, data):
            await renderer.feed(
                data,
                to: paneID,
                generation: TmuxConnectionGeneration(rawValue: generation)
            )
            guard generation == connectionGeneration else { return }
        case .exit:
            await connectionEnded(PierError.transport("tmux exited"), generation: generation)
            return
        case .windowAdded, .windowClosed, .windowRenamed, .layoutChanged, .sessionChanged, .sessionsChanged,
             .connectionClosed, .unknown: break
        }
        guard generation == connectionGeneration else { return }
        for continuation in subscribers.values {
            continuation.yield(message)
        }
    }

    private func handleBegin(_ actual: TmuxTransactionMarker, generation: UInt64) async {
        if let expected = startup?.marker {
            failStartup(TmuxStartupError.duplicateBegin(expected: expected, actual: actual))
        } else if startup != nil {
            startup?.marker = actual
        } else if let expected = pending.first?.marker {
            await connectionEnded(
                TmuxCommandProtocolError.duplicateBegin(expected: expected, actual: actual),
                generation: generation
            )
        } else if !pending.isEmpty {
            pending[0].marker = actual
        } else if let expected = unsolicitedMarker {
            await connectionEnded(
                TmuxCommandProtocolError.duplicateBegin(expected: expected, actual: actual),
                generation: generation
            )
        } else {
            unsolicitedMarker = actual
        }
    }

    private func handleResponseLine(_ line: String) {
        if startup?.marker != nil {
            startup?.response.append(line)
        } else if !pending.isEmpty, pending[0].marker != nil {
            pending[0].response.append(line)
        }
    }

    private func handleEnd(_ actual: TmuxTransactionMarker, generation: UInt64) async {
        if startup != nil {
            finishStartup(with: actual)
            return
        }
        if pending.isEmpty, unsolicitedMarker == actual {
            unsolicitedMarker = nil
            return
        }
        guard pending.first?.marker == actual else {
            await connectionEnded(
                TmuxCommandProtocolError.unexpectedEnd(expected: pending.first?.marker, actual: actual),
                generation: generation
            )
            return
        }
        let item = pending.removeFirst()
        item.continuation.resume(returning: item.response)
        sendNextIfNeeded()
    }

    private func handleCommandError(_ actual: TmuxTransactionMarker, generation: UInt64) async {
        if startup != nil {
            failStartupCommand(with: actual)
            return
        }
        if pending.isEmpty, unsolicitedMarker == actual {
            unsolicitedMarker = nil
            return
        }
        guard pending.first?.marker == actual else {
            await connectionEnded(
                TmuxCommandProtocolError.unexpectedCommandError(
                    expected: pending.first?.marker,
                    actual: actual
                ),
                generation: generation
            )
            return
        }
        let item = pending.removeFirst()
        item.continuation.resume(throwing: PierError.invalidResponse(item.response.joined(separator: "\n")))
        sendNextIfNeeded()
    }

    private func connectionEnded(_ error: Error, generation: UInt64? = nil) async {
        if let generation, generation != connectionGeneration { return }
        guard state != .disconnected else { return }
        connectionGeneration &+= 1
        let terminalGeneration = connectionGeneration
        readTask?.cancel()
        readTask = nil
        sendTask?.cancel()
        sendTask = nil
        transportGeneration = nil
        logger.log(.warning, "Connection ended: \(error)")
        failStartup(error)
        failPending(error)
        unsolicitedMarker = nil
        state = .connecting
        await transport.disconnect()
        guard terminalGeneration == connectionGeneration else { return }
        state = .disconnected
        let message = TmuxMessage.connectionClosed(reason: error.localizedDescription)
        for continuation in subscribers.values {
            continuation.yield(message)
        }
    }

    private func failPending(_ error: Error) {
        let items = pending; pending.removeAll()
        for item in items {
            item.continuation.resume(throwing: error)
        }
    }

    private func waitForStartup() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startup = StartupTransaction(continuation: continuation)
        }
    }

    private func finishStartup(with actual: TmuxTransactionMarker) {
        guard startup?.marker == actual else {
            failStartup(TmuxStartupError.unexpectedEnd(expected: startup?.marker, actual: actual))
            return
        }
        let transaction = startup
        startup = nil
        transaction?.continuation.resume()
    }

    private func failStartupCommand(with actual: TmuxTransactionMarker) {
        guard startup?.marker == actual else {
            failStartup(TmuxStartupError.unexpectedCommandError(expected: startup?.marker, actual: actual))
            return
        }
        failStartup(TmuxStartupError.commandFailed(startup?.response ?? []))
    }

    private func failStartup(_ error: Error) {
        let transaction = startup
        startup = nil
        transaction?.continuation.resume(throwing: error)
    }

    private func sendNextIfNeeded() {
        guard !pending.isEmpty, !pending[0].sent, let transportGeneration else { return }
        pending[0].sent = true
        let data = pending[0].data
        let generation = connectionGeneration
        sendTask = Task { [weak self, transport] in
            do {
                guard !Task.isCancelled else { return }
                try await transport.send(data, generation: transportGeneration)
                guard !Task.isCancelled else { return }
            } catch {
                await self?.sendFailed(error, generation: generation)
            }
        }
    }

    private func sendFailed(_ error: Error, generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        await connectionEnded(TmuxCommandWriteError.failed(Self.transportError(from: error)), generation: generation)
    }

    private static func transportError(from error: Error) -> PierError {
        if let error = error as? PierError { return error }
        return .transport(error.localizedDescription)
    }

    private func removeSubscriber(_ token: UInt64) {
        subscribers.removeValue(forKey: token)
    }

    private func makeToken() -> UInt64 {
        defer { nextToken &+= 1 }
        return nextToken
    }

    private static func replacingInvalidUTF8(in bytes: some Collection<UInt8>) -> String {
        // Lossy text is diagnostic-only after structural parsing has already failed.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
