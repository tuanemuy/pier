import PierDomain

public extension SessionCoordinator {
    func createWindow() async throws {
        try await withConnectedCommand { activeGeneration in
            guard let sessionID = self.model.selection?.sessionID else {
                throw SessionCommandError.disconnected
            }
            guard let previousSession = self.model.sessions.first(where: { $0.id == sessionID }) else {
                throw SessionCommandError.disconnected
            }
            let previousWindowIDs = Set(previousSession.windows.map(\.id))
            try await CreateWindow()(gateway: self.gateway, sessionID: sessionID)
            try await self.reloadSessionTree(generation: activeGeneration)
            let createdWindows = self.model.sessions.first(where: { $0.id == sessionID })?.windows
                .filter { !previousWindowIDs.contains($0.id) } ?? []
            guard createdWindows.count == 1, let created = createdWindows.first else {
                throw SessionCommandError.createdWindowCountMismatch(createdWindows.count)
            }
            try await SelectWindow()(gateway: self.gateway, windowID: created.id)
            try self.requireConnected(generation: activeGeneration)
            guard self.model.select(windowID: created.id) else { throw SessionCommandError.staleGeneration }
            if let paneID = created.activePaneID ?? created.panes.first?.id {
                try await SelectPane()(gateway: self.gateway, paneID: paneID)
                try self.requireConnected(generation: activeGeneration)
                guard self.model.select(paneID: paneID) else { throw SessionCommandError.staleGeneration }
                try await ZoomPane()(gateway: self.gateway, paneID: paneID)
            }
        }
    }

    func closeWindow(_ windowID: WindowID) async throws {
        try await commandAndReload { try await CloseWindow()(gateway: self.gateway, windowID: windowID) }
    }

    func selectWindow(_ windowID: WindowID) async throws {
        try await withConnectedCommand { activeGeneration in
            guard let session = self.model.sessions.first(where: { session in
                session.windows.contains(where: { $0.id == windowID })
            }),
                let window = session.windows.first(where: { $0.id == windowID }),
                let paneID = window.activePaneID ?? window.panes.first?.id
            else { throw SessionCommandError.staleGeneration }
            if self.context?.sessionName != session.name {
                try await SwitchSession()(gateway: self.gateway, sessionID: session.id)
                try self.requireConnected(generation: activeGeneration)
                guard let context = self.context else { throw SessionCommandError.disconnected }
                self.context = ConnectionContext(endpoint: context.endpoint, sessionName: session.name)
                guard self.model.select(sessionID: session.id) else { throw SessionCommandError.staleGeneration }
            }
            try await SelectWindow()(gateway: self.gateway, windowID: windowID)
            try self.requireConnected(generation: activeGeneration)
            guard self.model.select(windowID: windowID) else { throw SessionCommandError.staleGeneration }
            try await SelectPane()(gateway: self.gateway, paneID: paneID)
            try self.requireConnected(generation: activeGeneration)
            guard self.model.select(paneID: paneID) else { throw SessionCommandError.staleGeneration }
            try await ZoomPane()(gateway: self.gateway, paneID: paneID)
        }
    }

    func selectPane(_ paneID: PaneID) async throws {
        try await withConnectedCommand { activeGeneration in
            guard self.model.sessions.flatMap(\.windows).flatMap(\.panes).contains(where: { $0.id == paneID }) else {
                throw SessionCommandError.staleGeneration
            }
            try await SelectPane()(gateway: self.gateway, paneID: paneID)
            try self.requireConnected(generation: activeGeneration)
            guard self.model.select(paneID: paneID) else { throw SessionCommandError.staleGeneration }
            try await ZoomPane()(gateway: self.gateway, paneID: paneID)
        }
    }

    func splitPane(_ paneID: PaneID, direction: Direction) async throws {
        try await commandAndReload {
            try await SplitPane()(gateway: self.gateway, paneID: paneID, direction: direction)
        }
    }

    func closePane(_ paneID: PaneID) async throws {
        try await commandAndReload { try await ClosePane()(gateway: self.gateway, paneID: paneID) }
    }

    func movePane(_ paneID: PaneID, destination: WindowID) async throws {
        try await commandAndReload {
            try await MovePane()(gateway: self.gateway, paneID: paneID, destination: destination)
        }
    }

    func runCommand(_ command: String, paneID: PaneID) async throws {
        try await withConnectedCommand { activeGeneration in
            guard let pane = self.model.sessions
                .lazy
                .flatMap(\.windows)
                .lazy
                .flatMap(\.panes)
                .first(where: { $0.id == paneID })
            else { throw SessionCommandError.staleGeneration }
            let blockID = self.identifierGenerator.makeUUID()
            self.model.submit(
                command: command,
                paneID: paneID,
                blockID: blockID,
                now: self.clock.now()
            )
            do {
                try await RunCommand()(
                    command,
                    gateway: self.gateway,
                    paneID: paneID,
                    shell: pane.currentCommand
                )
                try self.requireConnected(generation: activeGeneration)
            } catch {
                self.model.rollbackSubmission(paneID: paneID, blockID: blockID)
                throw error
            }
        }
    }

    func sendNamedKey(_ key: TmuxKey, paneID: PaneID) async throws {
        try await withConnectedCommand { _ in
            try await SendKeys().named(key, gateway: self.gateway, paneID: paneID)
        }
    }

    func sendLiteralKeys(_ value: String, paneID: PaneID) async throws {
        try await withConnectedCommand { _ in
            try await SendKeys().literal(value, gateway: self.gateway, paneID: paneID)
        }
    }

    func resize(columns: Int, rows: Int) async throws {
        try await withConnectedCommand { _ in
            try await ResizeClient()(gateway: self.gateway, columns: columns, rows: rows)
        }
    }
}

extension SessionCoordinator {
    func apply(
        _ outcome: AttachSessionOutcome,
        sessionName: String,
        generation activeGeneration: UInt64,
        lease: SessionOperationLease
    ) async throws {
        let previousPaneIDs = Set(model.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        let currentPaneIDs = Set(outcome.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        for removedPaneID in previousPaneIDs.subtracting(currentPaneIDs) {
            try await validateOperation(generation: activeGeneration, lease: lease)
            await gateway.removeRenderedPane(removedPaneID, generation: outcome.connectionGeneration)
            await removeJournal(for: removedPaneID)
            try await validateOperation(generation: activeGeneration, lease: lease)
        }
        try await validateOperation(generation: activeGeneration, lease: lease)
        model.replaceSessions(outcome.sessions, preferredSessionName: sessionName)
        try await validateOperation(generation: activeGeneration, lease: lease)
        model.select(sessionID: outcome.attachedSessionID)
        for restored in outcome.restoredPanes where restored.presentation == .shell {
            try await validateOperation(generation: activeGeneration, lease: lease)
            let journal = await loadJournal(for: restored.pane.id)
            model.replaceScrollbackSnapshot(
                restored.capture,
                journal: journal,
                paneID: restored.pane.id,
                blockID: identifierGenerator.makeUUID(),
                now: clock.now()
            )
        }
    }

    func apply(_ restoredPanes: [RestoredPane]) async {
        let now = clock.now()
        for restored in restoredPanes where restored.presentation == .shell {
            let journal = await loadJournal(for: restored.pane.id)
            model.replaceScrollbackSnapshot(
                restored.capture,
                journal: journal,
                paneID: restored.pane.id,
                blockID: identifierGenerator.makeUUID(),
                now: now
            )
        }
    }

    func loadJournal(for paneID: PaneID) async -> [CommandBlock] {
        guard let key = journalKey(for: paneID) else { return [] }
        do {
            return try await commandJournal.load(for: key)
        } catch {
            logger.log(.warning, "Command journal load failed for \(paneID.rawValue): \(error.localizedDescription)")
            return []
        }
    }

    func persistBlocks(for paneID: PaneID) async {
        guard let key = journalKey(for: paneID), let blocks = model.blocks[paneID] else { return }
        let semanticBlocks = blocks.filter { $0.status != .restored }
        do {
            try await commandJournal.save(Array(semanticBlocks.suffix(200)), for: key)
        } catch {
            logger.log(.warning, "Command journal save failed for \(paneID.rawValue): \(error.localizedDescription)")
        }
    }

    func persistAllBlocks() async {
        for paneID in model.blocks.keys {
            await persistBlocks(for: paneID)
        }
    }

    func removeJournal(for paneID: PaneID) async {
        guard let key = journalKey(for: paneID) else { return }
        do {
            try await commandJournal.remove(for: key)
        } catch {
            logger.log(.warning, "Command journal removal failed for \(paneID.rawValue): \(error.localizedDescription)")
        }
    }

    private func journalKey(for paneID: PaneID) -> CommandJournalKey? {
        guard let context else { return nil }
        return CommandJournalKey(
            address: context.endpoint.address,
            username: context.endpoint.username,
            paneID: paneID
        )
    }

    func recordReconnectAttempt(_ attempt: Int, generation activeGeneration: UInt64) {
        guard activeGeneration == generation else { return }
        model.setConnection(.reconnecting(attempt: attempt))
    }

    func replaceCommandQueue() {
        commandQueue.invalidate()
        commandQueue = SessionCommandQueue(generation: generation)
    }

    func requireConnected(generation expectedGeneration: UInt64) throws {
        guard generation == expectedGeneration else { throw SessionCommandError.staleGeneration }
        guard context != nil, model.connection == .connected else { throw SessionCommandError.disconnected }
    }

    func validateOperation(generation expectedGeneration: UInt64, lease: SessionOperationLease) async throws {
        try await lease.check()
        guard generation == expectedGeneration else { throw SessionCommandError.staleGeneration }
    }

    func transitionToOwnedFailure(_ error: Error, generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration, model.connection == .connected else { return }
        let failure = SessionFailure.classify(error)
        commandQueue.invalidate()
        model.setConnection(.failed(failure))
        lastFailure = failure
    }

    func withConnectedCommand<Value: Sendable>(
        _ operation: @escaping @MainActor (UInt64) async throws -> Value
    ) async throws -> Value {
        guard context != nil, model.connection == .connected else {
            lastFailure = .command(.disconnected)
            throw SessionCommandError.disconnected
        }
        let activeGeneration = generation
        let queue = commandQueue
        guard queue.generation == activeGeneration else { throw SessionCommandError.staleGeneration }
        let previous = queue.tail
        let task = Task { @MainActor [weak self] () throws -> Value in
            await previous?.value
            guard let self else { throw SessionCommandError.staleGeneration }
            try self.requireConnected(generation: activeGeneration)
            do {
                let value = try await operation(activeGeneration)
                try self.requireConnected(generation: activeGeneration)
                return value
            } catch {
                guard self.generation == activeGeneration else {
                    if error is TmuxParseError || error is TmuxCommandProtocolError || error is TmuxCommandWriteError {
                        throw error
                    }
                    throw SessionCommandError.staleGeneration
                }
                throw error
            }
        }
        let ownershipToken = queue.own(task)
        queue.tail = Task { _ = await task.result }
        do {
            let value = try await task.value
            queue.release(ownershipToken)
            lastFailure = nil
            return value
        } catch {
            queue.release(ownershipToken)
            let failure = SessionFailure.classify(error)
            lastFailure = failure
            throw error
        }
    }

    private func commandAndReload(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await withConnectedCommand { activeGeneration in
            try await operation()
            try await self.reloadSessionTree(generation: activeGeneration)
        }
    }
}
