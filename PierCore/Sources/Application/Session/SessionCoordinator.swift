import Observation
import PierDomain

@MainActor @Observable
public final class SessionCoordinator {
    public let model: SessionModel
    public internal(set) var lastFailure: SessionFailure?

    @ObservationIgnored let gateway: TmuxGateway
    @ObservationIgnored let clock: any Clock
    @ObservationIgnored let identifierGenerator: any IdentifierGenerator
    @ObservationIgnored let logger: any PierLogger
    @ObservationIgnored let commandJournal: any CommandJournalPort
    @ObservationIgnored private let attachTimeout: Duration
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored var context: ConnectionContext?
    @ObservationIgnored private var operationLease: SessionOperationLease?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored var generation: UInt64 = 0
    @ObservationIgnored var commandQueue: SessionCommandQueue

    struct ConnectionContext {
        let endpoint: SSHEndpoint
        let sessionName: String
    }

    public init(
        gateway: TmuxGateway,
        clock: any Clock,
        identifierGenerator: any IdentifierGenerator,
        logger: any PierLogger = NullLogger(),
        commandJournal: any CommandJournalPort = NullCommandJournal(),
        model: SessionModel = SessionModel(),
        attachTimeout: Duration = .seconds(10)
    ) {
        self.gateway = gateway
        self.clock = clock
        self.identifierGenerator = identifierGenerator
        self.logger = logger
        self.commandJournal = commandJournal
        self.model = model
        self.attachTimeout = attachTimeout
        commandQueue = SessionCommandQueue(generation: 0)
    }

    deinit {
        observationTask?.cancel()
    }

    public func attach(endpoint: SSHEndpoint, sessionName: String) async throws {
        generation &+= 1
        replaceCommandQueue()
        observationTask?.cancel()
        observationTask = nil
        if let operationLease {
            await operationLease.invalidate()
            await gateway.disconnect()
        }
        let lease = SessionOperationLease()
        operationLease = lease
        context = ConnectionContext(endpoint: endpoint, sessionName: sessionName)
        isActive = true
        let activeGeneration = await beginObservation()
        model.setConnection(.connecting)
        do {
            let outcome = try await AttachSession(clock: clock, timeout: attachTimeout, logger: logger)(
                gateway: gateway,
                endpoint: endpoint,
                sessionName: sessionName,
                lease: lease
            )
            try await lease.check()
            guard activeGeneration == generation else {
                await gateway.disconnect(if: outcome.connectionGeneration)
                throw CancellationError()
            }
            try await apply(
                outcome,
                sessionName: sessionName,
                generation: activeGeneration,
                lease: lease
            )
            try await validateOperation(generation: activeGeneration, lease: lease)
            model.setConnection(.connected)
            lastFailure = nil
        } catch {
            guard activeGeneration == generation else { throw error }
            await gateway.disconnect()
            let failure = SessionFailure.classify(error)
            logger.log(.error, "Session attach failed [\(failure)]: \(error.localizedDescription)")
            model.setConnection(.failed(failure))
            lastFailure = failure
            throw error
        }
    }

    public func suspend() async {
        await persistAllBlocks()
        isActive = false
        generation &+= 1
        replaceCommandQueue()
        observationTask?.cancel()
        observationTask = nil
        model.setConnection(.disconnected)
        let lease = operationLease
        operationLease = nil
        await lease?.invalidate()
        await gateway.disconnect()
    }

    public func resume() async throws {
        guard let context else { return }
        switch model.connection {
        case .disconnected, .failed:
            break
        case .connecting, .connected, .reconnecting:
            return
        }
        if let operationLease { await operationLease.invalidate() }
        let lease = SessionOperationLease()
        operationLease = lease
        isActive = true
        let activeGeneration = await beginObservation()
        do {
            try await restore(context: context, generation: activeGeneration, lease: lease)
        } catch {
            guard activeGeneration == generation else { throw error }
            let failure = SessionFailure.classify(error)
            model.setConnection(.failed(failure))
            lastFailure = failure
            throw error
        }
    }

    public func disconnect() async {
        await persistAllBlocks()
        context = nil
        isActive = false
        generation &+= 1
        replaceCommandQueue()
        observationTask?.cancel()
        observationTask = nil
        model.setConnection(.disconnected)
        let lease = operationLease
        operationLease = nil
        await lease?.invalidate()
        await gateway.disconnect()
    }

    public func reloadSessionTree() async throws {
        try await withConnectedCommand { activeGeneration in
            try await self.reloadSessionTree(generation: activeGeneration)
        }
    }

    func reloadSessionTree(generation activeGeneration: UInt64) async throws {
        guard let context else { throw SessionCommandError.disconnected }
        let rendererGeneration = try await gateway.connectedGeneration()
        let tree = try await LoadSessionTree()(gateway: gateway)
        let previousPaneIDs = Set(model.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        guard let target = tree.first(where: { $0.name == context.sessionName }) else {
            throw AttachSessionError.sessionNotFound(context.sessionName)
        }
        let targetPanes = target.windows.flatMap(\.panes)
        let newPanes = targetPanes.filter { !previousPaneIDs.contains($0.id) }
        guard let operationLease else { throw SessionCommandError.disconnected }
        let restored: [RestoredPane]
        do {
            restored = try await BootstrapPanes(clock: clock, timeout: attachTimeout)(
                gateway: gateway,
                panes: newPanes,
                lease: operationLease
            )
        } catch {
            transitionToOwnedFailure(error, generation: activeGeneration)
            throw error
        }
        let currentPaneIDs = Set(tree.flatMap(\.windows).flatMap(\.panes).map(\.id))
        try requireConnected(generation: activeGeneration)
        await apply(restored)
        model.replaceSessions(tree, preferredSessionName: context.sessionName)
        for removedPaneID in previousPaneIDs.subtracting(currentPaneIDs) {
            await gateway.removeRenderedPane(removedPaneID, generation: rendererGeneration)
            await removeJournal(for: removedPaneID)
        }
    }

    private func beginObservation(cancelPrevious: Bool = true) async -> UInt64 {
        generation &+= 1
        replaceCommandQueue()
        let activeGeneration = generation
        if cancelPrevious { observationTask?.cancel() }
        let messages = await gateway.messages()
        observationTask = Task { [weak self] in
            for await message in messages {
                guard !Task.isCancelled else { return }
                await self?.consume(message, generation: activeGeneration)
            }
        }
        return activeGeneration
    }

    private func consume(_ message: TmuxMessage, generation activeGeneration: UInt64) async {
        guard activeGeneration == generation else { return }
        switch message {
        case let .output(paneID, data):
            let commandFinished = model.consumeShellOutput(
                data,
                paneID: paneID,
                now: clock.now(),
                blockID: identifierGenerator.makeUUID()
            )
            if commandFinished { await persistBlocks(for: paneID) }
        case .windowAdded, .windowClosed, .windowRenamed, .layoutChanged, .sessionChanged, .sessionsChanged:
            guard model.connection == .connected else { return }
            do {
                try await reloadSessionTree()
            } catch {
                guard activeGeneration == generation else { return }
                await gateway.disconnect()
                transitionToOwnedFailure(error, generation: activeGeneration)
            }
        case .connectionClosed, .exit:
            guard isActive, model.connection == .connected, let context else { return }
            generation &+= 1
            replaceCommandQueue()
            model.setConnection(.disconnected)
            await operationLease?.invalidate()
            let lease = SessionOperationLease()
            operationLease = lease
            let previousObservation = observationTask
            let reconnectGeneration = await beginObservation(cancelPrevious: false)
            do {
                try await restore(context: context, generation: reconnectGeneration, lease: lease)
                previousObservation?.cancel()
            } catch {
                previousObservation?.cancel()
                guard reconnectGeneration == generation else { return }
                let failure = SessionFailure.classify(error)
                model.setConnection(.failed(failure))
                lastFailure = failure
            }
        case .begin, .end, .commandError, .responseLine, .unknown:
            break
        }
    }

    private func restore(
        context: ConnectionContext,
        generation activeGeneration: UInt64,
        lease: SessionOperationLease
    ) async throws {
        try await lease.check()
        guard activeGeneration == generation else { throw CancellationError() }
        model.setConnection(.reconnecting(attempt: 1))
        let outcome = try await ReconnectAndRestore(clock: clock, attachTimeout: attachTimeout)(
            gateway: gateway,
            endpoint: context.endpoint,
            sessionName: context.sessionName,
            lease: lease,
            onAttempt: { [weak self] attempt in
                await self?.recordReconnectAttempt(attempt, generation: activeGeneration)
            }
        )
        try await lease.check()
        guard activeGeneration == generation else {
            await gateway.disconnect(if: outcome.connectionGeneration)
            throw CancellationError()
        }
        try await apply(
            outcome,
            sessionName: context.sessionName,
            generation: activeGeneration,
            lease: lease
        )
        try await validateOperation(generation: activeGeneration, lease: lease)
        model.setConnection(.connected)
        lastFailure = nil
    }
}
