import Foundation
import PierApplication
import PierDomain
import PierSupport
import XCTest

final class TmuxGatewayStartupTests: XCTestCase {
    func testConnectAcceptsChunkedControlModeEnvelope() async throws {
        let transport = FakeTransport(startupChunks: [
            "\u{1B}P10",
            "00p%begin 7 0 0\r\n",
            "%end 7 0 0\u{1B}",
            "\\\r\n"
        ])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())

        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        let state = await gateway.state
        XCTAssertEqual(state, .connected)
    }

    func testConnectPropagatesStartupCommandError() async throws {
        let transport = FakeTransport(startupChunks: [
            "%begin 7 0 0\nno server running on /tmp/tmux-501/default\n%error 7 0 0\n"
        ])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())

        do {
            try await gateway.connect(endpoint: endpoint, sessionName: "main")
            XCTFail("Expected startup command error")
        } catch {
            XCTAssertEqual(
                error as? TmuxStartupError,
                .commandFailed(["no server running on /tmp/tmux-501/default"])
            )
        }
        let state = await gateway.state
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectFailsOnMismatchedStartupEnd() async throws {
        let expected = TmuxTransactionMarker(timestamp: 7, commandNumber: 0, flags: 0)
        let actual = TmuxTransactionMarker(timestamp: 7, commandNumber: 1, flags: 0)
        let transport = FakeTransport(startupChunks: ["%begin 7 0 0\n%end 7 1 0\n"])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())

        do {
            try await gateway.connect(endpoint: endpoint, sessionName: "main")
            XCTFail("Expected mismatched startup end")
        } catch {
            XCTAssertEqual(error as? TmuxStartupError, .unexpectedEnd(expected: expected, actual: actual))
        }
    }

    func testConnectFailsOnMismatchedStartupError() async throws {
        let expected = TmuxTransactionMarker(timestamp: 7, commandNumber: 0, flags: 0)
        let actual = TmuxTransactionMarker(timestamp: 8, commandNumber: 0, flags: 0)
        let transport = FakeTransport(startupChunks: ["%begin 7 0 0\n%error 8 0 0\n"])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())

        do {
            try await gateway.connect(endpoint: endpoint, sessionName: "main")
            XCTFail("Expected mismatched startup error")
        } catch {
            XCTAssertEqual(
                error as? TmuxStartupError,
                .unexpectedCommandError(expected: expected, actual: actual)
            )
        }
    }

    func testConnectFailsOnDuplicateStartupBegin() async throws {
        let expected = TmuxTransactionMarker(timestamp: 7, commandNumber: 0, flags: 0)
        let actual = TmuxTransactionMarker(timestamp: 8, commandNumber: 0, flags: 0)
        let transport = FakeTransport(startupChunks: ["%begin 7 0 0\n%begin 8 0 0\n"])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())

        do {
            try await gateway.connect(endpoint: endpoint, sessionName: "main")
            XCTFail("Expected duplicate startup begin")
        } catch {
            XCTAssertEqual(error as? TmuxStartupError, .duplicateBegin(expected: expected, actual: actual))
        }
    }

    func testConnectFailsOnStartupEndBeforeBegin() async throws {
        let actual = TmuxTransactionMarker(timestamp: 7, commandNumber: 0, flags: 0)
        let transport = FakeTransport(startupChunks: ["%end 7 0 0\n"])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())

        do {
            try await gateway.connect(endpoint: endpoint, sessionName: "main")
            XCTFail("Expected startup end before begin")
        } catch {
            XCTAssertEqual(error as? TmuxStartupError, .unexpectedEnd(expected: nil, actual: actual))
        }
    }

    func testPublishesAsyncNotificationDuringStartup() async throws {
        let transport = FakeTransport(startupChunks: ["%begin 7 0 0\n%window-add @3\n%end 7 0 0\n"])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let messages = await gateway.messages()
        let notification = Task<WindowID?, Never> {
            for await message in messages {
                if case let .windowAdded(windowID) = message { return windowID }
            }
            return nil
        }

        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        let notifiedWindowID = await notification.value
        XCTAssertEqual(notifiedWindowID, try windowID("@3"))
    }

    func testConnectFailsWhenRawStreamEndsBeforeStartupResponse() async throws {
        let transport = FakeTransport(startupChunks: [])
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let targetEndpoint = endpoint
        let connection = Task { try await gateway.connect(endpoint: targetEndpoint, sessionName: "main") }
        while await transport.connections.isEmpty {
            await Task.yield()
        }
        await transport.finish()

        do {
            _ = try await connection.value
            XCTFail("Expected stream termination")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("SSH stream ended"))
        }
    }

    private var endpoint: SSHEndpoint {
        SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k"))
    }
}
