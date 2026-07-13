import Foundation
import PierApplication
import PierDomain
import PierSupport
import XCTest

// swiftlint:disable:next type_body_length
final class TmuxGatewayTests: XCTestCase {
    func testCorrelatesCommandResponseAndRoutesPaneOutput() async throws {
        let transport = FakeTransport(); let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let endpoint = SSHEndpoint(address: "host", username: "user", keyID: KeyID(rawValue: "key"))
        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        let response = Task { try await gateway.command("display-message hello") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%begin 10 1 0\nhello\n%output %2 abc\\015\\012\n%end 10 1 0\n")

        let lines = try await response.value
        let output = try await renderer.output[paneID("%2")]
        XCTAssertEqual(lines, ["hello"])
        XCTAssertEqual(output, Data("abc\r\n".utf8))
    }

    func testInvalidTerminalBytesDoNotDisconnectGateway() async throws {
        let transport = FakeTransport(); let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let endpoint = SSHEndpoint(address: "host", username: "user", keyID: KeyID(rawValue: "key"))
        let pane = try paneID("%2")
        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        var line = Data("%output %2 raw:".utf8)
        line.append(contentsOf: [0xFF, 0x0A])
        await transport.yield(line)

        while await renderer.output[pane] == nil {
            await Task.yield()
        }
        let output = await renderer.output[pane]
        let state = await gateway.state
        XCTAssertEqual(output, Data([0x72, 0x61, 0x77, 0x3A, 0xFF]))
        XCTAssertEqual(state, .connected)
    }

    func testLiteralInputIsShellQuoted() async throws {
        let transport = FakeTransport(); let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "dev's"
        )
        let task = Task { try await SendKeys().literal("日本語's", gateway: gateway, paneID: paneID("%1")) }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%begin 1 1 0\n%end 1 1 0\n")
        try await task.value
        let sent = await transport.sent
        XCTAssertEqual(sent.first?.contains("send-keys -t %1 -l '日本語'\\''s'"), true)
    }

    func testNamedInputUsesValidatedTmuxKeyToken() async throws {
        let transport = FakeTransport(); let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        let task = Task {
            try await SendKeys().named(.control(.upward), gateway: gateway, paneID: paneID("%1"))
        }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%begin 1 1 0\n%end 1 1 0\n")
        try await task.value

        let sent = await transport.sent
        XCTAssertEqual(sent, ["send-keys -t %1 C-Up\n"])
    }

    func testCommandsAreWrittenInFIFOOrder() async throws {
        let transport = FakeTransport(); let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        let first = Task { try await gateway.command("first") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        let second = Task { try await gateway.command("second") }
        let firstWrite = await transport.sent
        XCTAssertEqual(firstWrite, ["first\n"])
        await transport.yield("%begin 1 1 0\n%end 1 1 0\n")
        while await transport.sent.count < 2 {
            await Task.yield()
        }
        let bothWrites = await transport.sent
        XCTAssertEqual(bothWrites, ["first\n", "second\n"])
        await transport.yield("%begin 2 2 0\n%end 2 2 0\n")
        _ = try await (first.value, second.value)
    }

    func testStalledOldSendCannotWriteIntoReconnectedTransportGeneration() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let endpoint = SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k"))
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        await transport.stallFollowingSend()
        let stale = Task { try await gateway.command("display-message stale") }
        await transport.waitUntilSendStalled()

        await gateway.disconnect()
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        await transport.resumeSends()
        do {
            _ = try await stale.value
            XCTFail("Expected stale command failure")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Disconnected"))
        }

        let current = Task { try await gateway.command("display-message current") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%begin 2 2 0\ncurrent\n%end 2 2 0\n")
        let response = try await current.value
        XCTAssertEqual(response, ["current"])
        let sent = await transport.sent
        XCTAssertEqual(sent, ["display-message current\n"])
    }

    func testSendFailureTerminatesConnectionAndFailsEntireFIFO() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        await transport.failFollowingSends(1)
        let first = Task { try await gateway.command("first") }
        let second = Task { try await gateway.command("second") }
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Expected terminal write failure")
            } catch {
                XCTAssertEqual(
                    error as? TmuxCommandWriteError,
                    .failed(.transport("send failed"))
                )
            }
        }
        let state = await gateway.state
        let sent = await transport.sent
        XCTAssertEqual(state, .disconnected)
        XCTAssertEqual(sent, [])
    }

    func testMalformedEndTerminatesPendingCommandWithTypedParseError() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        let command = Task { try await gateway.command("display-message blocked") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%end malformed\n")
        do {
            _ = try await command.value
            XCTFail("Expected malformed marker failure")
        } catch {
            XCTAssertEqual(error as? TmuxParseError, .malformed("%end malformed"))
        }
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    func testMalformedOutputTerminatesPendingCommandInsteadOfDroppingOutput() async throws {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        let command = Task { try await gateway.command("display-message blocked") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%output %1 \\99\n")
        do {
            _ = try await command.value
            XCTFail("Expected malformed output failure")
        } catch {
            XCTAssertEqual(error as? TmuxParseError, .invalidOctalEscape("\\99"))
        }
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    func testReconnectRestoresCapturedPaneAfterTransientFailure() async throws {
        let transport = FakeTransport(connectionFailures: 1); let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let paneID = try paneID("%7")
        let restore = Task {
            try await ReconnectAndRestore(clock: ImmediateClock())(
                gateway: gateway,
                endpoint: SSHEndpoint(address: "host", username: "user", keyID: KeyID(rawValue: "key")),
                sessionName: "main"
            )
        }
        while true {
            let connectionCount = await transport.connections.count
            let sent = await transport.sent
            if connectionCount >= 2, !sent.isEmpty { break }
            await Task.yield()
        }
        let delimiter = SessionTreeRecordFormat.delimiter
        let window = ["$1", "main", "@1", "0", "main", "1"].joined(separator: delimiter)
        await transport.yield("%begin 2 1 0\n\(window)\n%end 2 1 0\n")
        while await transport.sent.count < 2 {
            await Task.yield()
        }
        let pane = ["$1", "@1", "%7", "0", "0", "shell", "sh", "/tmp", "0", "1"]
            .joined(separator: delimiter)
        await transport.yield("%begin 3 2 0\n\(pane)\n%end 3 2 0\n")
        while await transport.sent.count < 3 {
            await Task.yield()
        }
        await transport.yield("%begin 4 3 0\nrestored screen\n%end 4 3 0\n")
        _ = try await restore.value
        let captured = await renderer.output[paneID]
        let connectionCount = await transport.connections.count
        XCTAssertEqual(captured, Data("restored screen\n".utf8))
        XCTAssertEqual(connectionCount, 2)
    }

    func testLoadsSessionTreeIncludingPaneWorkingDirectory() async throws {
        let transport = FakeTransport(); let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        let load = Task { try await LoadSessionTree()(gateway: gateway) }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        let delimiter = SessionTreeRecordFormat.delimiter
        let windowRecord = ["$1", "main", "@2", "0", "editor", "1"].joined(separator: delimiter)
        await transport.yield("%begin 1 1 0\n\(windowRecord)\n%end 1 1 0\n")
        while await transport.sent.count < 2 {
            await Task.yield()
        }
        let paneRecord = ["$1", "@2", "%3", "0", "0", "code", "zsh", "/home/me/project", "0", "1"]
            .joined(separator: delimiter)
        await transport.yield("%begin 2 2 0\n\(paneRecord)\n%end 2 2 0\n")
        let sessions = try await load.value
        let sent = await transport.sent
        XCTAssertEqual(sessions.first?.windows.first?.panes.first?.currentPath, "/home/me/project")
        XCTAssertEqual(sessions.first?.activeWindowID, try windowID("@2"))
        XCTAssertTrue(sent[0].contains(SessionTreeRecordFormat.windows))
        XCTAssertTrue(sent[1].contains(SessionTreeRecordFormat.panes))
    }

    func testLoadSessionTreePropagatesMalformedRecordError() async throws {
        let transport = FakeTransport(); let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        let load = Task { try await LoadSessionTree()(gateway: gateway) }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        let malformed = ["$1", "main", "@1", "not-an-index", "editor", "1"]
            .joined(separator: SessionTreeRecordFormat.delimiter)
        await transport.yield("%begin 1 1 0\n\(malformed)\n%end 1 1 0\n")
        while await transport.sent.count < 2 {
            await Task.yield()
        }
        await transport.yield("%begin 2 2 0\n%end 2 2 0\n")

        do {
            _ = try await load.value
            XCTFail("Expected malformed record error")
        } catch {
            XCTAssertEqual(
                error as? SessionTreeParseError,
                .malformedRecord(kind: .window, lineNumber: 1, line: malformed)
            )
        }
    }

    @MainActor func testRestoresCapturedShellScrollbackAsVisibleBlock() throws {
        let model = SessionModel()
        let paneID = try paneID("%9")
        let blockID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000009"))
        model.replaceScrollbackSnapshot(
            Data("\u{1B}[32mready\u{1B}[0m\n".utf8),
            paneID: paneID,
            blockID: blockID,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(model.blocks[paneID]?.first?.output, "ready")
        XCTAssertEqual(model.blocks[paneID]?.first?.status, .restored)
    }

    func testPublishesConnectionClosureForAutomaticReconnect() async throws {
        let transport = FakeTransport(); let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let messages = await gateway.messages()
        let closure = Task {
            for await message in messages {
                if case let .connectionClosed(reason) = message { return reason }
            }
            return "missing"
        }
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k")),
            sessionName: "main"
        )
        await transport.yield("%exit server-ended\n")
        let reason = await closure.value
        let state = await gateway.state
        XCTAssertEqual(reason, "tmux exited")
        XCTAssertEqual(state, .disconnected)
    }
}
