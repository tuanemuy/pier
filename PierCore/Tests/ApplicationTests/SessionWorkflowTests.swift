import Foundation
import PierApplication
import PierDomain
import PierSupport
import XCTest

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
final class SessionWorkflowTests: XCTestCase {
    func testAttachRestoresShellAndTUIAndInstallsOnlyShellIntegration() async throws {
        let transport = FakeTransport()
        let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }

        await Self.respondTree(on: transport, panes: [
            ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/work", "0", "1"],
            ["$1", "@1", "%2", "1", "0", "editor", "vim", "/work", "1", "0"]
        ])
        await Self.respond(on: transport, commandIndex: 2, body: "shell scrollback", marker: 3)
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: "", marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "tui screen", marker: 6)

        let outcome = try await attach.value
        XCTAssertEqual(outcome.restoredPanes.map(\.presentation), [.shell, .terminal])
        XCTAssertEqual(outcome.restoredPanes.map(\.capture), [
            Data("shell scrollback\n".utf8),
            Data("tui screen\n".utf8)
        ])
        let sent = await transport.sent
        XCTAssertEqual(sent.count(where: { $0.contains("send-keys") }), 2)
        XCTAssertTrue(sent.filter { $0.hasPrefix("capture-pane") }.allSatisfy { $0.contains(" -S - ") })
        let rendered = try await renderer.output[paneID("%2")]
        XCTAssertEqual(rendered, Data("tui screen\n".utf8))
    }

    @MainActor func testRunCommandOwnsBlockBeforeTrailingOutputInCommandChunk() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let targetPaneID = try paneID("%1")

        let command = Task {
            try await coordinator.runCommand("printf hello", paneID: targetPaneID)
        }
        while await transport.sent.count < 4 {
            await Task.yield()
        }
        let sent = await transport.sent
        XCTAssertTrue(sent[3].contains("send-keys -t %1 -l"))
        XCTAssertTrue(sent[3].contains("133;D;%d"))
        await transport.yield(
            "%begin 4 4 0\n%end 4 4 0\n%output %1 \\033]133;C\\007hello\\033]133;D;0\\007\n"
        )
        try await command.value
        while coordinator.model.blocks[targetPaneID]?.last?.status != .finished(exitCode: 0) {
            await Task.yield()
        }

        let block = try XCTUnwrap(coordinator.model.blocks[targetPaneID]?.last)
        XCTAssertEqual(block.command, "printf hello")
        XCTAssertEqual(block.output, "hello")
    }

    @MainActor func testCommandJournalRestoresSemanticBlocksIntoNewCoordinatorInstance() async throws {
        let transport = FakeTransport()
        let journal = InMemoryCommandJournal()
        let firstCoordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator(),
            commandJournal: journal
        )
        try await attach(coordinator: firstCoordinator, transport: transport)
        let targetPaneID = try paneID("%1")
        let key = CommandJournalKey(address: "host", username: "user", paneID: targetPaneID)

        let command = Task { try await firstCoordinator.runCommand("printf hello", paneID: targetPaneID) }
        while await transport.sent.count < 4 {
            await Task.yield()
        }
        await transport.yield(
            "%begin 4 4 0\n%end 4 4 0\n%output %1 \\033]133;C\\007hello\\033]133;D;0\\007\n"
        )
        try await command.value
        while await journal.load(for: key).last?.status != .finished(exitCode: 0) {
            await Task.yield()
        }
        await firstCoordinator.disconnect()

        let secondID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        let secondCoordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator(value: secondID),
            commandJournal: journal
        )
        let secondAttach = Task {
            try await secondCoordinator.attach(endpoint: endpoint, sessionName: "main")
        }
        await Self.respond(on: transport, commandIndex: 4, body: Self.treeWindowRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: Self.treePaneRecord(), marker: 6)
        await Self.respond(
            on: transport,
            commandIndex: 6,
            body: "desktop history\n$ printf hello\nhello",
            marker: 7
        )
        try await secondAttach.value

        let blocks = try XCTUnwrap(secondCoordinator.model.blocks[targetPaneID])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].status, .restored)
        XCTAssertEqual(blocks[0].output, "desktop history\n$")
        XCTAssertEqual(blocks[1].command, "printf hello")
        XCTAssertEqual(blocks[1].output, "hello")
        XCTAssertEqual(blocks[1].status, .finished(exitCode: 0))
    }

    @MainActor func testSelectingWindowInAnotherSessionSwitchesReconnectTarget() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let current = try XCTUnwrap(coordinator.model.selectedSession)
        let otherSessionID = try sessionID("$2")
        let otherWindowID = try windowID("@2")
        let otherPaneID = try paneID("%2")
        let otherPane = Pane(id: otherPaneID, position: GridPosition(x: 0, y: 0), currentCommand: "sh")
        let otherWindow = TmuxWindow(
            id: otherWindowID,
            index: 0,
            name: "other",
            panes: [otherPane],
            activePaneID: otherPaneID
        )
        coordinator.model.replaceSessions([
            current,
            TmuxSession(id: otherSessionID, name: "other", windows: [otherWindow], activeWindowID: otherWindowID)
        ])

        let selection = Task { try await coordinator.selectWindow(otherWindowID) }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: "", marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "", marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: "", marker: 7)
        try await selection.value

        let sent = await transport.sent
        XCTAssertEqual(sent[3], "switch-client -t $2\n")
        XCTAssertEqual(coordinator.model.selectedSession?.name, "other")

        await coordinator.suspend()
        let resume = Task { try await coordinator.resume() }
        while await transport.connections.count < 2 {
            await Task.yield()
        }
        let connections = await transport.connections
        let reconnectCommand = try XCTUnwrap(connections.last?.1)
        XCTAssertTrue(reconnectCommand.contains("new-session -A -s 'other'"))
        await coordinator.disconnect()
        _ = await resume.result
    }

    func testAttachOnlyBootstrapsPanesFromSelectedSession() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        let delimiter = SessionTreeRecordFormat.delimiter
        let windows = [
            ["$1", "main", "@1", "0", "main", "1"].joined(separator: delimiter),
            ["$2", "other", "@2", "0", "other", "1"].joined(separator: delimiter)
        ].joined(separator: "\n")
        let panes = [
            ["$1", "@1", "%1", "0", "0", "main", "zsh", "/main", "0", "1"].joined(separator: delimiter),
            ["$2", "@2", "%9", "0", "0", "other", "zsh", "/other", "0", "1"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 0, body: windows, marker: 1)
        await Self.respond(on: transport, commandIndex: 1, body: panes, marker: 2)
        await Self.respond(on: transport, commandIndex: 2, body: "main only", marker: 3)
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: "", marker: 5)

        let outcome = try await attach.value
        let sent = await transport.sent
        XCTAssertEqual(outcome.restoredPanes.map(\.pane.id), try [paneID("%1")])
        XCTAssertFalse(sent.contains(where: { $0.contains("%9") }))
    }

    func testAttachPropagatesMalformedTreeWithoutCapturing() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        await Self.respond(on: transport, commandIndex: 0, body: "malformed", marker: 1)
        await Self.respond(on: transport, commandIndex: 1, body: "", marker: 2)

        do {
            _ = try await attach.value
            XCTFail("Expected malformed tree")
        } catch {
            XCTAssertEqual(
                error as? SessionTreeParseError,
                .malformedRecord(kind: .window, lineNumber: 1, line: "malformed")
            )
        }
        let sentCount = await transport.sent.count
        XCTAssertEqual(sentCount, 2)
    }

    func testAttachStartupTimeoutIsTypedAndDisconnects() async throws {
        let transport = FakeTransport(startupChunks: [], suspendsConnections: true)
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        do {
            _ = try await AttachSession(clock: TimeoutClock())(
                gateway: gateway,
                endpoint: endpoint,
                sessionName: "main"
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, .timedOut(stage: .startup))
        }
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    @MainActor func testCoordinatorStartupStreamLossRemainsTypedAttachFailure() async throws {
        let transport = FakeTransport(startupChunks: [])
        await transport.failFollowingStartupStreams(1)
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )

        do {
            try await coordinator.attach(endpoint: endpoint, sessionName: "main")
            XCTFail("Expected startup stream loss")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("startup stream lost"))
        }
        XCTAssertEqual(coordinator.model.connection, .failed(.transport(.transport("startup stream lost"))))
        XCTAssertEqual(coordinator.lastFailure, .transport(.transport("startup stream lost")))
        let gatewayState = await gateway.state
        XCTAssertEqual(gatewayState, .disconnected)
    }

    @MainActor func testCoordinatorIgnoresStructuralNotificationsDuringStartup() async throws {
        let transport = FakeTransport(startupChunks: [
            "%begin 1 0 0\n%session-changed $1 main\n%window-add @1\n%end 1 0 0\n"
        ])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )

        try await attach(coordinator: coordinator, transport: transport)

        XCTAssertEqual(coordinator.model.connection, .connected)
        let gatewayState = await gateway.state
        XCTAssertEqual(gatewayState, .connected)
    }

    func testAttachSessionTreeTimeoutStopsBeforePaneQueryAndCleansOwnedConnection() async throws {
        let transport = FakeTransport()
        let clock = ManualTimeoutClock()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: clock)(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        while await transport.sent.count < 1 {
            await Task.yield()
        }
        await clock.waitForSleepCount(2)
        await clock.fireNewest()

        do {
            _ = try await attach.value
            XCTFail("Expected session tree timeout")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, .timedOut(stage: .sessionTree))
        }
        let sent = await transport.sent
        let state = await gateway.state
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].hasPrefix("list-windows"))
        XCTAssertEqual(state, .disconnected)
    }

    func testAttachCaptureTimeoutStopsBeforeIntegrationAndCleansOwnedConnection() async throws {
        let transport = FakeTransport()
        let clock = ManualTimeoutClock()
        let targetPaneID = try paneID("%1")
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: clock)(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        await Self.respondTree(on: transport, panes: [
            ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/work", "0", "1"]
        ])
        while await transport.sent.count < 3 {
            await Task.yield()
        }
        await clock.waitForSleepCount(3)
        await clock.fireNewest()

        do {
            _ = try await attach.value
            XCTFail("Expected capture timeout")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, .timedOut(stage: .capture(targetPaneID)))
        }
        let sent = await transport.sent
        let state = await gateway.state
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent[2].hasPrefix("capture-pane"))
        XCTAssertFalse(sent.contains(where: { $0.contains("send-keys") }))
        XCTAssertEqual(state, .disconnected)
    }

    func testAttachShellIntegrationTimeoutStopsBeforeEnterAndCleansOwnedConnection() async throws {
        let transport = FakeTransport()
        let clock = ManualTimeoutClock()
        let targetPaneID = try paneID("%1")
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: clock)(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        await Self.respondTree(on: transport, panes: [
            ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/work", "0", "1"]
        ])
        await Self.respond(on: transport, commandIndex: 2, body: "captured", marker: 3)
        while await transport.sent.count < 4 {
            await Task.yield()
        }
        await clock.waitForSleepCount(4)
        await clock.fireNewest()

        do {
            _ = try await attach.value
            XCTFail("Expected shell integration timeout")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, .timedOut(stage: .shellIntegration(targetPaneID)))
        }
        let sent = await transport.sent
        let state = await gateway.state
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(sent[3].contains("send-keys"))
        XCTAssertFalse(sent.contains(where: { $0.hasSuffix(" Enter\n") }))
        XCTAssertEqual(state, .disconnected)
    }

    func testAttachSessionNotFoundIsTypedAndCleansConnection() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let attach = Task {
            try await AttachSession(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        let otherWindow = ["$2", "other", "@2", "0", "other", "1"]
            .joined(separator: SessionTreeRecordFormat.delimiter)
        await Self.respond(on: transport, commandIndex: 0, body: otherWindow, marker: 1)
        await Self.respond(on: transport, commandIndex: 1, body: "", marker: 2)

        do {
            _ = try await attach.value
            XCTFail("Expected missing attached session")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, .sessionNotFound("main"))
        }
        let gatewayState = await gateway.state
        XCTAssertEqual(gatewayState, .disconnected)
    }

    func testLivePaneBootstrapCaptureTimeoutIsTypedAndCleansOwnedGeneration() async throws {
        let transport = FakeTransport()
        let clock = ManualTimeoutClock()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        let targetPaneID = try paneID("%7")
        let pane = Pane(id: targetPaneID, position: GridPosition(x: 0, y: 0), currentCommand: "zsh")
        let bootstrap = Task {
            try await BootstrapPanes(clock: clock)(
                gateway: gateway,
                panes: [pane],
                lease: SessionOperationLease()
            )
        }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await clock.waitForSleepCount(1)
        await clock.fireNewest()
        do {
            _ = try await bootstrap.value
            XCTFail("Expected bootstrap timeout")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, .timedOut(stage: .capture(targetPaneID)))
        }
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    func testReconnectDoesNotRetryMalformedTreeAndCanConnectAgain() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let restore = Task {
            try await ReconnectAndRestore(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: targetEndpoint,
                sessionName: "main"
            )
        }
        await Self.respond(on: transport, commandIndex: 0, body: "malformed", marker: 1)
        await Self.respond(on: transport, commandIndex: 1, body: "", marker: 2)

        do {
            _ = try await restore.value
            XCTFail("Expected malformed tree")
        } catch {
            XCTAssertTrue(error is SessionTreeParseError)
        }
        let failedConnectionCount = await transport.connections.count
        let disconnectedState = await gateway.state
        XCTAssertEqual(failedConnectionCount, 1)
        XCTAssertEqual(disconnectedState, .disconnected)
        try await gateway.connect(endpoint: targetEndpoint, sessionName: "main")
        let connectedState = await gateway.state
        XCTAssertEqual(connectedState, .connected)
        await gateway.disconnect()
    }

    func testReconnectExhaustsExactAttemptsAndLeavesGatewayClean() async throws {
        let transport = FakeTransport(connectionFailures: 3)
        let attempts = AttemptRecorder()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        do {
            _ = try await ReconnectAndRestore(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: endpoint,
                sessionName: "main",
                maximumAttempts: 3,
                onAttempt: { await attempts.record($0) }
            )
            XCTFail("Expected retry exhaustion")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("temporary"))
        }
        let connectionCount = await transport.connections.count
        let gatewayState = await gateway.state
        XCTAssertEqual(connectionCount, 3)
        XCTAssertEqual(gatewayState, .disconnected)
        let recordedAttempts = await attempts.values
        XCTAssertEqual(recordedAttempts, [1, 2, 3])
        XCTAssertEqual(ReconnectAndRestore.backoff(for: Int.max), .seconds(4))
    }

    @MainActor func testCoordinatorReconnectStartupStreamLossRetriesAndRecovers() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await transport.failFollowingStartupStreams(1)

        await transport.yield("%exit lost\n")
        while await transport.connections.count < 3 {
            await Task.yield()
        }
        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: Self.treePaneRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "recovered", marker: 6)
        while coordinator.model.connection != .connected {
            await Task.yield()
        }

        let connectionCount = await transport.connections.count
        XCTAssertEqual(connectionCount, 3)
        XCTAssertNil(coordinator.lastFailure)
        XCTAssertEqual(try coordinator.model.blocks[paneID("%1")]?.map(\.output), ["recovered"])
    }

    func testReconnectRejectsInvalidMaximumAttemptsWithoutConnecting() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        do {
            _ = try await ReconnectAndRestore(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: endpoint,
                sessionName: "main",
                maximumAttempts: 0
            )
            XCTFail("Expected invalid attempts")
        } catch {
            XCTAssertEqual(error as? ReconnectAndRestoreError, .invalidMaximumAttempts(0))
        }
        let connectionCount = await transport.connections.count
        XCTAssertEqual(connectionCount, 0)
        do {
            _ = try await ReconnectAndRestore(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: endpoint,
                sessionName: "main",
                maximumAttempts: ReconnectAndRestore.maximumSupportedAttempts + 1
            )
            XCTFail("Expected capped attempts")
        } catch {
            XCTAssertEqual(
                error as? ReconnectAndRestoreError,
                .invalidMaximumAttempts(ReconnectAndRestore.maximumSupportedAttempts + 1)
            )
        }
    }

    @MainActor func testSelectionTransitionsRemainAtomicAcrossTreeReplacement() throws {
        let model = SessionModel()
        let first = try makeSession(
            id: sessionID("$1"),
            windowID: windowID("@1"),
            paneID: paneID("%1"),
            name: "one"
        )
        let second = try makeSession(
            id: sessionID("$2"),
            windowID: windowID("@2"),
            paneID: paneID("%2"),
            name: "two"
        )
        model.replaceSessions([first, second])
        XCTAssertTrue(try model.select(paneID: paneID("%2")))
        XCTAssertEqual(
            model.selection,
            try SessionSelection(sessionID: sessionID("$2"), windowID: windowID("@2"), paneID: paneID("%2"))
        )
        model.replaceSessions([first])
        XCTAssertEqual(
            model.selection,
            try SessionSelection(sessionID: sessionID("$1"), windowID: windowID("@1"), paneID: paneID("%1"))
        )
        XCTAssertFalse(try model.select(paneID: paneID("%9")))
        XCTAssertEqual(model.selectedPaneID, try paneID("%1"))
    }

    @MainActor func testRemotePaneSelectionFailureLeavesLocalSelectionUnchanged() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let firstPaneID = try paneID("%1")
        let secondPaneID = try paneID("%2")
        let secondPane = Pane(id: secondPaneID, position: GridPosition(x: 1, y: 0), currentCommand: "sh")
        let current = try XCTUnwrap(coordinator.model.selectedSession)
        let window = try XCTUnwrap(current.windows.first)
        let expandedWindow = TmuxWindow(
            id: window.id,
            index: window.index,
            name: window.name,
            panes: window.panes + [secondPane],
            activePaneID: firstPaneID
        )
        coordinator.model.replaceSessions([
            TmuxSession(id: current.id, name: current.name, windows: [expandedWindow], activeWindowID: window.id)
        ])
        let previousSelection = coordinator.model.selection
        let sentCount = await transport.sent.count
        let selection = Task { try await coordinator.selectPane(secondPaneID) }
        while await transport.sent.count == sentCount {
            await Task.yield()
        }
        await transport.yield("%begin 20 20 0\nselection failed\n%error 20 20 0\n")

        do {
            try await selection.value
            XCTFail("Expected remote selection failure")
        } catch {
            XCTAssertEqual(error as? PierError, .invalidResponse("selection failed"))
        }
        XCTAssertEqual(coordinator.model.selection, previousSelection)
    }

    @MainActor func testPaneZoomFailureKeepsLocalSelectionReconciledToSuccessfulRemoteSelection() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let secondPaneID = try paneID("%2")
        let current = try XCTUnwrap(coordinator.model.selectedSession)
        let window = try XCTUnwrap(current.windows.first)
        let secondPane = Pane(id: secondPaneID, position: GridPosition(x: 1, y: 0), currentCommand: "sh")
        let expanded = TmuxWindow(
            id: window.id,
            index: window.index,
            name: window.name,
            panes: window.panes + [secondPane],
            activePaneID: window.activePaneID
        )
        coordinator.model.replaceSessions([
            TmuxSession(id: current.id, name: current.name, windows: [expanded], activeWindowID: window.id)
        ])
        let selection = Task { try await coordinator.selectPane(secondPaneID) }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        await Self.respondError(on: transport, commandIndex: 4, body: "zoom failed", marker: 5)

        do {
            try await selection.value
            XCTFail("Expected zoom failure")
        } catch {
            XCTAssertEqual(error as? PierError, .invalidResponse("zoom failed"))
        }
        XCTAssertEqual(coordinator.model.selectedPaneID, secondPaneID)
    }

    @MainActor func testWindowFollowupPaneFailureKeepsLocalSelectionReconciledToRemoteWindow() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let current = try XCTUnwrap(coordinator.model.selectedSession)
        let secondWindowID = try windowID("@2")
        let secondPaneID = try paneID("%2")
        let secondPane = Pane(id: secondPaneID, position: GridPosition(x: 0, y: 0), currentCommand: "sh")
        let secondWindow = TmuxWindow(
            id: secondWindowID,
            index: 1,
            name: "second",
            panes: [secondPane],
            activePaneID: secondPaneID
        )
        coordinator.model.replaceSessions([
            TmuxSession(
                id: current.id,
                name: current.name,
                windows: current.windows + [secondWindow],
                activeWindowID: current.activeWindowID
            )
        ])
        let selection = Task { try await coordinator.selectWindow(secondWindowID) }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        await Self.respondError(on: transport, commandIndex: 4, body: "pane failed", marker: 5)

        do {
            try await selection.value
            XCTFail("Expected pane followup failure")
        } catch {
            XCTAssertEqual(error as? PierError, .invalidResponse("pane failed"))
        }
        XCTAssertEqual(coordinator.model.selectedWindowID, secondWindowID)
        XCTAssertEqual(coordinator.model.selectedPaneID, secondPaneID)
    }

    @MainActor func testCreateWindowFollowupPaneFailureKeepsCreatedWindowSelected() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let creation = Task { try await coordinator.createWindow() }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        let delimiter = SessionTreeRecordFormat.delimiter
        let windows = [
            Self.treeWindowRecord(),
            ["$1", "main", "@2", "1", "created", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@2", "%2", "0", "0", "created", "sh", "/work", "0", "1"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 4, body: windows, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: panes, marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: "created", marker: 7)
        await Self.respond(on: transport, commandIndex: 7, body: "", marker: 8)
        await Self.respondError(on: transport, commandIndex: 8, body: "pane failed", marker: 9)

        do {
            try await creation.value
            XCTFail("Expected created pane selection failure")
        } catch {
            XCTAssertEqual(error as? PierError, .invalidResponse("pane failed"))
        }
        XCTAssertEqual(coordinator.model.selectedWindowID, try windowID("@2"))
        XCTAssertEqual(coordinator.model.selectedPaneID, try paneID("%2"))
    }

    @MainActor func testCreateWindowBootstrapFailureTransitionsCoordinatorToTypedFailure() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let creation = Task { try await coordinator.createWindow() }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        let delimiter = SessionTreeRecordFormat.delimiter
        let windows = [
            Self.treeWindowRecord(),
            ["$1", "main", "@2", "1", "created", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@2", "%2", "0", "0", "created", "zsh", "/work", "0", "1"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 4, body: windows, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: panes, marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: "created", marker: 7)
        await Self.respondError(on: transport, commandIndex: 7, body: "integration failed", marker: 8)
        do {
            try await creation.value
            XCTFail("Expected create bootstrap failure")
        } catch {
            XCTAssertEqual(error as? PierError, .invalidResponse("integration failed"))
        }
        XCTAssertEqual(
            coordinator.model.connection,
            .failed(.transport(.invalidResponse("integration failed")))
        )
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    @MainActor func testCreateWindowFailsWhenTargetSessionHasNoNewWindow() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let creation = Task { try await coordinator.createWindow() }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: Self.treeWindowRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: Self.treePaneRecord(), marker: 6)

        do {
            try await creation.value
            XCTFail("Expected missing created window failure")
        } catch {
            XCTAssertEqual(error as? SessionCommandError, .createdWindowCountMismatch(0))
        }
        XCTAssertEqual(coordinator.model.selectedWindowID, try windowID("@1"))
    }

    @MainActor func testCreateWindowIgnoresConcurrentWindowInOtherSession() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let creation = Task { try await coordinator.createWindow() }
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        let delimiter = SessionTreeRecordFormat.delimiter
        let windows = [
            Self.treeWindowRecord(),
            ["$2", "other", "@9", "0", "other", "1"].joined(separator: delimiter)
        ].joined(separator: "\n")
        let panes = [
            Self.treePaneRecord(),
            ["$2", "@9", "%9", "0", "0", "other", "vim", "/other", "1", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 4, body: windows, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: panes, marker: 6)

        do {
            try await creation.value
            XCTFail("Expected target-session window failure")
        } catch {
            XCTAssertEqual(error as? SessionCommandError, .createdWindowCountMismatch(0))
        }
        XCTAssertEqual(coordinator.model.selectedSession?.name, "main")
    }

    @MainActor func testCoordinatorCommandsAreSerializedFIFO() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let selectedPaneID = try XCTUnwrap(coordinator.model.selectedPaneID)
        let first = Task { try await coordinator.sendNamedKey(.arrow(.leftward), paneID: selectedPaneID) }
        while await transport.sent.count < 4 {
            await Task.yield()
        }
        let second = Task { try await coordinator.sendNamedKey(.arrow(.rightward), paneID: selectedPaneID) }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let blockedCount = await transport.sent.count
        XCTAssertEqual(blockedCount, 4)
        await Self.respond(on: transport, commandIndex: 3, body: "", marker: 4)
        while await transport.sent.count < 5 {
            await Task.yield()
        }
        await Self.respond(on: transport, commandIndex: 4, body: "", marker: 5)
        try await first.value
        try await second.value
        let sent = await transport.sent
        XCTAssertTrue(sent[3].contains("Left"))
        XCTAssertTrue(sent[4].contains("Right"))
    }

    @MainActor func testNewGenerationCommandQueueDoesNotWaitForStalledOldBootstrap() async throws {
        let transport = FakeTransport()
        let renderer = SwitchableStallingRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await renderer.stallNextFeed()
        let reload = Task { try await coordinator.reloadSessionTree() }
        let delimiter = SessionTreeRecordFormat.delimiter
        let window = Self.treeWindowRecord()
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@1", "%2", "1", "0", "new", "sh", "/work", "0", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 3, body: window, marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: panes, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "old bootstrap", marker: 6)
        await renderer.waitUntilStalled()

        await coordinator.suspend()
        let resume = Task { try await coordinator.resume() }
        await Self.respond(on: transport, commandIndex: 6, body: Self.treeWindowRecord(), marker: 7)
        await Self.respond(on: transport, commandIndex: 7, body: Self.treePaneRecord(), marker: 8)
        await Self.respond(on: transport, commandIndex: 8, body: "new generation", marker: 9)
        try await resume.value
        XCTAssertEqual(coordinator.model.connection, .connected)

        await renderer.resume()
        do {
            try await reload.value
            XCTFail("Expected stale old bootstrap")
        } catch {
            XCTAssertTrue(error is SessionCommandError || error is TmuxConnectionError || error is CancellationError)
        }
    }

    @MainActor func testStalledOutcomeApplyCannotCommitAfterSuspend() async throws {
        let transport = FakeTransport()
        let renderer = SwitchableStallingRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await renderer.stallNextRemove()
        let targetEndpoint = endpoint
        let replacement = Task {
            try await coordinator.attach(endpoint: targetEndpoint, sessionName: "second")
        }
        let delimiter = SessionTreeRecordFormat.delimiter
        let window = ["$2", "second", "@2", "0", "second", "1"].joined(separator: delimiter)
        let pane = ["$2", "@2", "%2", "0", "0", "editor", "vim", "/second", "1", "0"]
            .joined(separator: delimiter)
        await Self.respond(on: transport, commandIndex: 3, body: window, marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: pane, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "replacement", marker: 6)
        await renderer.waitUntilStalled()

        await coordinator.suspend()
        await renderer.resume()
        do {
            try await replacement.value
            XCTFail("Expected stale replacement attach")
        } catch {
            XCTAssertTrue(error is CancellationError || error is SessionCommandError)
        }
        XCTAssertEqual(coordinator.model.connection, .disconnected)
        XCTAssertEqual(coordinator.model.selectedSession?.name, "main")
        XCTAssertNil(try coordinator.model.blocks[paneID("%2")])
    }

    @MainActor func testNaturalReconnectRotatesQueuePastStalledOldBootstrap() async throws {
        let transport = FakeTransport()
        let renderer = SwitchableStallingRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await renderer.stallNextFeed()
        let reload = Task { try await coordinator.reloadSessionTree() }
        let delimiter = SessionTreeRecordFormat.delimiter
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@1", "%2", "1", "0", "new", "sh", "/work", "0", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: panes, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "old bootstrap", marker: 6)
        do {
            try await waitUntil("old bootstrap renderer to stall") {
                await renderer.hasStalled
            }

            await transport.yield("%exit lost\n")
            try await waitUntil("replacement transport connection") {
                await transport.connections.count >= 2
            }
            await Self.respond(on: transport, commandIndex: 6, body: Self.treeWindowRecord(), marker: 7)
            await Self.respond(on: transport, commandIndex: 7, body: Self.treePaneRecord(), marker: 8)
            await Self.respond(on: transport, commandIndex: 8, body: "new generation", marker: 9)
            try await waitUntil("coordinator to finish reconnecting") {
                coordinator.model.connection == .connected
            }
        } catch {
            reload.cancel()
            await renderer.resume()
            throw error
        }

        await renderer.resume()
        do {
            try await reload.value
            XCTFail("Expected stale old reload")
        } catch {
            XCTAssertEqual(error as? SessionCommandError, .staleGeneration)
        }
        XCTAssertEqual(try coordinator.model.blocks[paneID("%1")]?.map(\.output), ["new generation"])
    }

    @MainActor func testCommandCatchBeforeConnectionClosedStillAutoRestores() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await transport.suspendFollowingDisconnect()
        let selectedPaneID = try XCTUnwrap(coordinator.model.selectedPaneID)
        let command = Task { try await coordinator.sendNamedKey(.arrow(.leftward), paneID: selectedPaneID) }
        while await transport.sent.count < 4 {
            await Task.yield()
        }
        await transport.yield("%end 99 99 0\n")

        do {
            try await command.value
            XCTFail("Expected protocol terminal command failure")
        } catch {
            XCTAssertTrue(error is TmuxCommandProtocolError)
        }
        XCTAssertEqual(coordinator.model.connection, .connected)

        await transport.resumeDisconnects()
        while await transport.connections.count < 2 {
            await Task.yield()
        }
        await Self.respond(on: transport, commandIndex: 4, body: Self.treeWindowRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: Self.treePaneRecord(), marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: "restored", marker: 7)
        while coordinator.model.connection != .connected {
            await Task.yield()
        }
        XCTAssertNil(coordinator.lastFailure)
    }

    @MainActor func testConnectionClosedBeforeCommandRejectionStillAutoRestores() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let selectedPaneID = try XCTUnwrap(coordinator.model.selectedPaneID)

        await transport.yield("%exit lost\n")
        while coordinator.model.connection != .reconnecting(attempt: 1) {
            await Task.yield()
        }
        do {
            try await coordinator.sendNamedKey(.arrow(.leftward), paneID: selectedPaneID)
            XCTFail("Expected reconnecting command rejection")
        } catch {
            XCTAssertEqual(error as? SessionCommandError, .disconnected)
        }

        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: Self.treePaneRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "restored", marker: 6)
        while coordinator.model.connection != .connected {
            await Task.yield()
        }
        XCTAssertNil(coordinator.lastFailure)
    }

    @MainActor func testMalformedLiveProtocolFailsCoordinatorQueueAndAutoRestores() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let selectedPaneID = try XCTUnwrap(coordinator.model.selectedPaneID)
        let first = Task { try await coordinator.sendNamedKey(.arrow(.leftward), paneID: selectedPaneID) }
        while await transport.sent.count < 4 {
            await Task.yield()
        }
        let queued = Task { try await coordinator.sendNamedKey(.arrow(.rightward), paneID: selectedPaneID) }
        await transport.yield("%output %1 \\99\n")

        do {
            try await first.value
            XCTFail("Expected typed parse failure")
        } catch {
            XCTAssertEqual(error as? TmuxParseError, .invalidOctalEscape("\\99"))
        }
        while await transport.connections.count < 2 {
            await Task.yield()
        }
        await Self.respond(on: transport, commandIndex: 4, body: Self.treeWindowRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: Self.treePaneRecord(), marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: "restored", marker: 7)
        while coordinator.model.connection != .connected {
            await Task.yield()
        }
        do {
            try await queued.value
            XCTFail("Expected queued command invalidation")
        } catch {
            XCTAssertTrue(error is SessionCommandError || error is CancellationError)
        }
        XCTAssertNil(coordinator.lastFailure)
    }

    @MainActor func testShellIntegrationBootstrapFailureTransitionsFailedAndCanRecover() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let reload = Task { try await coordinator.reloadSessionTree() }
        let delimiter = SessionTreeRecordFormat.delimiter
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@1", "%2", "1", "0", "new", "zsh", "/work", "0", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: panes, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "captured", marker: 6)
        await Self.respondError(on: transport, commandIndex: 6, body: "integration failed", marker: 7)
        do {
            try await reload.value
            XCTFail("Expected integration failure")
        } catch {
            XCTAssertEqual(error as? PierError, .invalidResponse("integration failed"))
        }
        XCTAssertEqual(
            coordinator.model.connection,
            .failed(.transport(.invalidResponse("integration failed")))
        )
        let failedGatewayState = await gateway.state
        XCTAssertEqual(failedGatewayState, .disconnected)

        let resume = Task { try await coordinator.resume() }
        await Self.respond(on: transport, commandIndex: 7, body: Self.treeWindowRecord(), marker: 8)
        await Self.respond(on: transport, commandIndex: 8, body: Self.treePaneRecord(), marker: 9)
        await Self.respond(on: transport, commandIndex: 9, body: "recovered", marker: 10)
        try await resume.value
        XCTAssertEqual(coordinator.model.connection, .connected)
    }

    @MainActor func testCoordinatorCaptureTimeoutCleansUpAndResumeRecovers() async throws {
        let transport = FakeTransport()
        let clock = ManualTimeoutClock()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: clock,
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        let reload = Task { try await coordinator.reloadSessionTree() }
        let delimiter = SessionTreeRecordFormat.delimiter
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@1", "%2", "1", "0", "new", "zsh", "/work", "0", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: panes, marker: 5)
        while await transport.sent.count < 6 {
            await Task.yield()
        }
        await clock.waitForSleepCount(5)
        await clock.fireNewest()

        do {
            try await reload.value
            XCTFail("Expected capture timeout")
        } catch {
            XCTAssertEqual(error as? AttachSessionError, try .timedOut(stage: .capture(paneID("%2"))))
        }
        XCTAssertEqual(
            coordinator.model.connection,
            try .failed(.attach(.timedOut(stage: .capture(paneID("%2")))))
        )
        let failedState = await gateway.state
        XCTAssertEqual(failedState, .disconnected)

        let resume = Task { try await coordinator.resume() }
        await Self.respond(on: transport, commandIndex: 6, body: Self.treeWindowRecord(), marker: 7)
        await Self.respond(on: transport, commandIndex: 7, body: Self.treePaneRecord(), marker: 8)
        await Self.respond(on: transport, commandIndex: 8, body: "resumed", marker: 9)
        try await resume.value
        XCTAssertEqual(coordinator.model.connection, .connected)
        XCTAssertNil(coordinator.lastFailure)
    }

    @MainActor func testNotificationBootstrapFailureIsSurfacedAsTypedFailedState() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await transport.yield("%window-add @2\n")
        let delimiter = SessionTreeRecordFormat.delimiter
        let panes = [
            Self.treePaneRecord(),
            ["$1", "@1", "%2", "1", "0", "new", "zsh", "/work", "0", "0"].joined(separator: delimiter)
        ].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: panes, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "captured", marker: 6)
        await Self.respondError(on: transport, commandIndex: 6, body: "notification integration failed", marker: 7)
        while true {
            if case .failed = coordinator.model.connection { break }
            await Task.yield()
        }
        XCTAssertEqual(
            coordinator.lastFailure,
            .transport(.invalidResponse("notification integration failed"))
        )
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    @MainActor func testCoordinatorRejectsDisconnectedAndStaleCommandsWithTypedErrors() async throws {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(
            gateway: TmuxGateway(transport: transport, renderer: FakeRenderer()),
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        do {
            try await coordinator.resize(columns: 80, rows: 24)
            XCTFail("Expected disconnected rejection")
        } catch {
            XCTAssertEqual(error as? SessionCommandError, .disconnected)
        }

        try await attach(coordinator: coordinator, transport: transport)
        let selectedPaneID = try XCTUnwrap(coordinator.model.selection?.paneID)
        let sentCount = await transport.sent.count
        let command = Task { try await coordinator.sendLiteralKeys("echo stale", paneID: selectedPaneID) }
        while await transport.sent.count == sentCount {
            await Task.yield()
        }
        await coordinator.suspend()

        do {
            try await command.value
            XCTFail("Expected stale generation rejection")
        } catch {
            XCTAssertEqual(error as? SessionCommandError, .staleGeneration)
        }
    }

    @MainActor func testCoordinatorFoldsOutputAndReconnectsWithinItsGeneration() async throws {
        let transport = FakeTransport()
        let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        let targetEndpoint = endpoint
        let attachment = Task {
            try await coordinator.attach(endpoint: targetEndpoint, sessionName: "main")
        }
        await Self.respondTree(on: transport, panes: [
            ["$1", "@1", "%1", "0", "0", "shell", "sh", "/work", "0", "1"]
        ])
        await Self.respond(on: transport, commandIndex: 2, body: "initial", marker: 3)
        try await attachment.value

        let selectedPaneID = try paneID("%1")
        coordinator.model.submit(
            command: "echo hello",
            paneID: selectedPaneID,
            blockID: FixedIdentifierGenerator().makeUUID(),
            now: ImmediateClock().now()
        )
        await transport.yield("%output %1 \\033]133;C\\007hello\\033]133;D;0\\007\n")
        while coordinator.model.blocks[selectedPaneID]?.last?.status != .finished(exitCode: 0) {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.model.blocks[selectedPaneID]?.last?.output, "hello")

        await transport.yield("%exit lost\n")
        await Self.respond(on: transport, commandIndex: 3, body: Self.treeWindowRecord(), marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: Self.treePaneRecord(), marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "restored", marker: 6)
        while coordinator.model.connection != .connected {
            await Task.yield()
        }
        let rendered = await renderer.output[selectedPaneID]
        XCTAssertEqual(rendered, Data("restored\n".utf8))
        XCTAssertEqual(coordinator.model.blocks[selectedPaneID]?.map(\.output), ["restored"])

        await coordinator.suspend()
        XCTAssertEqual(coordinator.model.connection, .disconnected)
        let blockCount = coordinator.model.blocks[selectedPaneID]?.count
        await transport.yield("%output %1 stale\n")
        await Task.yield()
        XCTAssertEqual(coordinator.model.blocks[selectedPaneID]?.count, blockCount)
    }

    @MainActor func testNotificationBootstrapsNewShellPaneBeforePublishingTree() async throws {
        let transport = FakeTransport()
        let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await transport.yield("%window-add @2\n")
        let delimiter = SessionTreeRecordFormat.delimiter
        let windows = [["$1", "main", "@2", "1", "new", "1"].joined(separator: delimiter)]
            .joined(separator: "\n")
        let panes = [["$1", "@2", "%2", "0", "0", "new", "zsh", "/work", "0", "1"]
            .joined(separator: delimiter)].joined(separator: "\n")
        await Self.respond(on: transport, commandIndex: 3, body: windows, marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: panes, marker: 5)
        await Self.respond(on: transport, commandIndex: 5, body: "new snapshot", marker: 6)
        while await transport.sent.count < 7 {
            await Task.yield()
        }
        let newPaneID = try paneID("%2")
        XCTAssertFalse(coordinator.model.sessions.flatMap(\.windows).flatMap(\.panes).contains { $0.id == newPaneID })
        await Self.respond(on: transport, commandIndex: 6, body: "", marker: 7)
        await Self.respond(on: transport, commandIndex: 7, body: "", marker: 8)
        while !coordinator.model.sessions.flatMap(\.windows).flatMap(\.panes).contains(where: { $0.id == newPaneID }) {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.model.blocks[newPaneID]?.map(\.output), ["new snapshot"])
        let sent = await transport.sent
        XCTAssertEqual(sent.count(where: { $0.contains("send-keys -t %2") }), 2)
        let removedPaneIDs = await renderer.removed
        XCTAssertEqual(removedPaneIDs, try [paneID("%1")])
    }

    @MainActor func testTreeReplacementPrunesRemovedPaneStateAndRenderer() throws {
        let model = SessionModel()
        let first = try makeSession(id: sessionID("$1"), windowID: windowID("@1"), paneID: paneID("%1"), name: "main")
        let secondPane = try Pane(id: paneID("%2"), position: GridPosition(x: 1, y: 0), currentCommand: "sh")
        let window = try TmuxWindow(
            id: windowID("@1"),
            index: 0,
            name: "main",
            panes: [first.windows[0].panes[0], secondPane],
            activePaneID: paneID("%1")
        )
        let session = try TmuxSession(id: sessionID("$1"), name: "main", windows: [window], activeWindowID: window.id)
        model.replaceSessions([session])
        let generator = FixedIdentifierGenerator()
        let now = ImmediateClock().now()
        try model.submit(command: "keep", paneID: paneID("%1"), blockID: generator.makeUUID(), now: now)
        try model.submit(command: "stale", paneID: paneID("%2"), blockID: generator.makeUUID(), now: now)
        model.replaceSessions([first])
        XCTAssertNotNil(try model.blocks[paneID("%1")])
        XCTAssertNil(try model.blocks[paneID("%2")])
    }

    @MainActor func testSupersedingAttachCancelsOldGenerationAndPublishesOnlyNewSession() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        let targetEndpoint = endpoint
        let first = Task { try await coordinator.attach(endpoint: targetEndpoint, sessionName: "first") }
        while await transport.sent.count < 1 {
            await Task.yield()
        }
        let second = Task { try await coordinator.attach(endpoint: targetEndpoint, sessionName: "second") }
        while await transport.connections.count < 2 {
            await Task.yield()
        }
        let delimiter = SessionTreeRecordFormat.delimiter
        let window = ["$2", "second", "@2", "0", "second", "1"].joined(separator: delimiter)
        let pane = ["$2", "@2", "%2", "0", "0", "second", "sh", "/second", "0", "1"].joined(separator: delimiter)
        await Self.respond(on: transport, commandIndex: 1, body: window, marker: 1)
        await Self.respond(on: transport, commandIndex: 2, body: pane, marker: 2)
        await Self.respond(on: transport, commandIndex: 3, body: "second", marker: 3)
        try await second.value
        do {
            try await first.value
            XCTFail("Expected superseded first attach")
        } catch {
            switch SessionFailure.classify(error) {
            case .cancelled, .connection, .transport:
                break
            case .attach, .sessionTree, .startup, .commandProtocol, .commandWrite, .command, .tmuxParse, .unclassified:
                XCTFail("Unexpected superseded attach failure: \(error)")
            }
        }
        XCTAssertEqual(coordinator.model.selectedSession?.name, "second")
        let connectionCount = await transport.connections.count
        let gatewayState = await gateway.state
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(gatewayState, .connected)
    }

    @MainActor func testSuspendInterruptsCancellationInsensitiveReconnectTransport() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await transport.suspendFollowingConnection()
        await transport.yield("%exit lost\n")
        while await transport.connections.count < 2 {
            await Task.yield()
        }

        await coordinator.suspend()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let connectionCount = await transport.connections.count
        let gatewayState = await gateway.state
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(gatewayState, .disconnected)
        XCTAssertEqual(coordinator.model.connection, .disconnected)
    }

    @MainActor func testCoordinatorFailureIsCleanAndExplicitResumeCanRecover() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)

        await transport.yield("%exit lost\n")
        await Self.respond(on: transport, commandIndex: 3, body: "malformed", marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: "", marker: 5)
        while true {
            if case .failed = coordinator.model.connection { break }
            await Task.yield()
        }
        let failedGatewayState = await gateway.state
        XCTAssertEqual(failedGatewayState, .disconnected)

        let resume = Task { try await coordinator.resume() }
        await Self.respond(on: transport, commandIndex: 5, body: Self.treeWindowRecord(), marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: Self.treePaneRecord(), marker: 7)
        await Self.respond(on: transport, commandIndex: 7, body: "recovered", marker: 8)
        try await resume.value

        XCTAssertEqual(coordinator.model.connection, .connected)
        XCTAssertEqual(try coordinator.model.blocks[paneID("%1")]?.map(\.output), ["recovered"])
    }

    @MainActor func testNotificationTreeReloadFailureIsVisibleCleanAndRecoverable() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: ImmediateClock(),
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)

        await transport.yield("%window-add @2\n")
        await Self.respond(on: transport, commandIndex: 3, body: "malformed", marker: 4)
        await Self.respond(on: transport, commandIndex: 4, body: "", marker: 5)
        while true {
            if case .failed = coordinator.model.connection { break }
            await Task.yield()
        }
        let failedState = await gateway.state
        XCTAssertEqual(failedState, .disconnected)
        XCTAssertEqual(
            coordinator.lastFailure,
            .sessionTree(.malformedRecord(kind: .window, lineNumber: 1, line: "malformed"))
        )

        let resume = Task { try await coordinator.resume() }
        await Self.respond(on: transport, commandIndex: 5, body: Self.treeWindowRecord(), marker: 6)
        await Self.respond(on: transport, commandIndex: 6, body: Self.treePaneRecord(), marker: 7)
        await Self.respond(on: transport, commandIndex: 7, body: "reloaded", marker: 8)
        try await resume.value

        XCTAssertEqual(coordinator.model.connection, .connected)
        XCTAssertNil(coordinator.lastFailure)
        XCTAssertEqual(try coordinator.model.blocks[paneID("%1")]?.map(\.output), ["reloaded"])
    }

    @MainActor func testSuspendDuringCancellationInsensitiveBackoffPreventsAnotherAttempt() async throws {
        let transport = FakeTransport()
        let clock = BackoffClock()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let coordinator = SessionCoordinator(
            gateway: gateway,
            clock: clock,
            identifierGenerator: FixedIdentifierGenerator()
        )
        try await attach(coordinator: coordinator, transport: transport)
        await transport.failFollowingConnections(1)
        await transport.yield("%exit lost\n")
        await clock.waitUntilBackoff()

        await coordinator.suspend()
        await clock.resumeBackoff()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let connectionCount = await transport.connections.count
        let gatewayState = await gateway.state
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(gatewayState, .disconnected)
        XCTAssertEqual(coordinator.model.connection, .disconnected)
    }

    private var endpoint: SSHEndpoint {
        SSHEndpoint(address: "host", username: "user", keyID: KeyID(rawValue: "key"))
    }

    private static func respondTree(on transport: FakeTransport, panes: [[String]]) async {
        await respond(on: transport, commandIndex: 0, body: treeWindowRecord(), marker: 1)
        let paneRecords = panes.map { $0.joined(separator: SessionTreeRecordFormat.delimiter) }
            .joined(separator: "\n")
        await respond(on: transport, commandIndex: 1, body: paneRecords, marker: 2)
    }

    private static func treeWindowRecord() -> String {
        ["$1", "main", "@1", "0", "main", "1"].joined(separator: SessionTreeRecordFormat.delimiter)
    }

    private static func treePaneRecord() -> String {
        ["$1", "@1", "%1", "0", "0", "shell", "sh", "/work", "0", "1"]
            .joined(separator: SessionTreeRecordFormat.delimiter)
    }

    private static func respond(on transport: FakeTransport, commandIndex: Int, body: String, marker: UInt64) async {
        while await transport.sent.count <= commandIndex {
            await Task.yield()
        }
        let responseBody = body.isEmpty ? "" : "\(body)\n"
        await transport.yield("%begin \(marker) \(marker) 0\n\(responseBody)%end \(marker) \(marker) 0\n")
    }

    private static func respondError(
        on transport: FakeTransport,
        commandIndex: Int,
        body: String,
        marker: UInt64
    ) async {
        while await transport.sent.count <= commandIndex {
            await Task.yield()
        }
        await transport.yield("%begin \(marker) \(marker) 0\n\(body)\n%error \(marker) \(marker) 0\n")
    }

    @MainActor private func attach(coordinator: SessionCoordinator, transport: FakeTransport) async throws {
        let targetEndpoint = endpoint
        let task = Task { try await coordinator.attach(endpoint: targetEndpoint, sessionName: "main") }
        await Self.respondTree(on: transport, panes: [
            ["$1", "@1", "%1", "0", "0", "shell", "sh", "/work", "0", "1"]
        ])
        await Self.respond(on: transport, commandIndex: 2, body: "initial", marker: 3)
        try await task.value
    }

    @MainActor private func waitUntil(
        _ condition: String,
        timeout: Duration = .seconds(2),
        predicate: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !predicate() {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw TestWaitTimeout(condition: condition, timeout: timeout)
            }
            await Task.yield()
        }
    }

    private func makeSession(id: SessionID, windowID: WindowID, paneID: PaneID, name: String) -> TmuxSession {
        let pane = Pane(id: paneID, position: GridPosition(x: 0, y: 0), currentCommand: "zsh")
        let window = TmuxWindow(id: windowID, index: 0, name: name, panes: [pane], activePaneID: paneID)
        return TmuxSession(id: id, name: name, windows: [window], activeWindowID: windowID)
    }
}

private actor BackoffClock: Clock {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    nonisolated func now() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    func sleep(for duration: Duration) async throws {
        if duration.components.seconds > 0 {
            try await Task.sleep(for: .seconds(3600))
            return
        }
        isWaiting = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBackoff() async {
        if isWaiting { return }
        await withCheckedContinuation { entered = $0 }
    }

    func resumeBackoff() {
        continuation?.resume()
        continuation = nil
    }
}

private struct TimeoutClock: Clock {
    func now() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    func sleep(for _: Duration) async throws {}
}

private actor ManualTimeoutClock: Clock {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var sleepCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated func now() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    func sleep(for _: Duration) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                sleepCount += 1
                let ready = waiters.filter { $0.0 <= sleepCount }
                waiters.removeAll { $0.0 <= sleepCount }
                for waiter in ready {
                    waiter.1.resume()
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitForSleepCount(_ target: Int) async {
        if sleepCount >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func fireNewest() {
        guard let id = continuations.keys.max(), let continuation = continuations.removeValue(forKey: id) else {
            return
        }
        continuation.resume()
    }

    private func cancel(id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor AttemptRecorder {
    private(set) var values: [Int] = []
    func record(_ value: Int) {
        values.append(value)
    }
}

private actor SwitchableStallingRenderer: PaneRendererPort {
    private var generation: TmuxConnectionGeneration?
    private var shouldStall = false
    private var stalled = false
    private var entered: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldStallRemove = false

    var hasStalled: Bool {
        stalled
    }

    func activate(generation: TmuxConnectionGeneration) {
        if self.generation == nil || generation.rawValue >= self.generation?.rawValue ?? 0 {
            self.generation = generation
        }
    }

    func feed(_: sending Data, to _: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == self.generation else { return }
        if shouldStall {
            shouldStall = false
            stalled = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func reset(paneID _: PaneID, generation _: TmuxConnectionGeneration) async {}
    func remove(paneID _: PaneID, generation _: TmuxConnectionGeneration) async {
        if shouldStallRemove {
            shouldStallRemove = false
            stalled = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func stallNextFeed() {
        shouldStall = true
    }

    func stallNextRemove() {
        shouldStallRemove = true
    }

    func waitUntilStalled() async {
        if stalled { return }
        await withCheckedContinuation { entered = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct TestWaitTimeout: LocalizedError {
    let condition: String
    let timeout: Duration

    var errorDescription: String? {
        "Timed out after \(timeout) waiting for \(condition)"
    }
}

// swiftlint:enable file_length
