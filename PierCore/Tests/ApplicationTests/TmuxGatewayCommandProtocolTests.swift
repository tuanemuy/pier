import Foundation
import PierApplication
import PierDomain
import XCTest

final class TmuxGatewayCommandProtocolTests: XCTestCase {
    func testRejectsMismatchedCommandEnd() async throws {
        let expected = marker(commandNumber: 1)
        let actual = marker(commandNumber: 2)
        let (gateway, transport) = try await connectedGateway()
        let command = Task { try await gateway.command("first") }
        await waitForCommand(on: transport)
        await transport.yield("%begin 10 1 0\n%end 10 2 0\n")

        await assertFailure(command, equals: .unexpectedEnd(expected: expected, actual: actual))
    }

    func testRejectsMismatchedCommandError() async throws {
        let expected = marker(commandNumber: 1)
        let actual = marker(commandNumber: 2)
        let (gateway, transport) = try await connectedGateway()
        let command = Task { try await gateway.command("first") }
        await waitForCommand(on: transport)
        await transport.yield("%begin 10 1 0\n%error 10 2 0\n")

        await assertFailure(command, equals: .unexpectedCommandError(expected: expected, actual: actual))
    }

    func testRejectsDuplicateCommandBegin() async throws {
        let expected = marker(commandNumber: 1)
        let actual = marker(commandNumber: 2)
        let (gateway, transport) = try await connectedGateway()
        let command = Task { try await gateway.command("first") }
        await waitForCommand(on: transport)
        await transport.yield("%begin 10 1 0\n%begin 10 2 0\n")

        await assertFailure(command, equals: .duplicateBegin(expected: expected, actual: actual))
    }

    func testRejectsCommandEndBeforeBegin() async throws {
        let actual = marker(commandNumber: 1)
        let (gateway, transport) = try await connectedGateway()
        let command = Task { try await gateway.command("first") }
        await waitForCommand(on: transport)
        await transport.yield("%end 10 1 0\n")

        await assertFailure(command, equals: .unexpectedEnd(expected: nil, actual: actual))
    }

    func testAcceptsCompleteUnsolicitedTransactionBetweenCommands() async throws {
        let (gateway, transport) = try await connectedGateway()
        let messages = await gateway.messages()
        let hookCompleted = Task {
            for await message in messages where message == .end(timestamp: 10, commandNumber: 7, flags: 1) {
                return
            }
        }
        await transport.yield("%begin 10 7 1\nhook output\n%end 10 7 1\n")
        await hookCompleted.value

        let command = Task { try await gateway.command("first") }
        await waitForCommand(on: transport)
        await transport.yield("%begin 10 8 0\nok\n%end 10 8 0\n")

        let response = try await command.value
        XCTAssertEqual(response, ["ok"])
        let state = await gateway.state
        XCTAssertEqual(state, .connected)
    }

    func testRejectsConcurrentConnectWithoutReplacingFirstContinuation() async throws {
        let transport = FakeTransport(suspendsConnections: true)
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        let endpoint = endpoint
        let first = Task { try await gateway.connect(endpoint: endpoint, sessionName: "main") }
        while await transport.connections.isEmpty {
            await Task.yield()
        }

        do {
            try await gateway.connect(endpoint: endpoint, sessionName: "other")
            XCTFail("Expected concurrent connection rejection")
        } catch {
            XCTAssertEqual(error as? TmuxConnectionError, .connectionInProgress)
        }
        await transport.resumeConnections()
        _ = try await first.value
    }

    private func connectedGateway() async throws -> (TmuxGateway, FakeTransport) {
        let transport = FakeTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        return (gateway, transport)
    }

    private func waitForCommand(on transport: FakeTransport) async {
        while await transport.sent.isEmpty {
            await Task.yield()
        }
    }

    private func assertFailure(
        _ task: Task<[String], any Error>,
        equals expected: TmuxCommandProtocolError
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected command protocol error")
        } catch {
            XCTAssertEqual(error as? TmuxCommandProtocolError, expected)
        }
    }

    private func marker(commandNumber: UInt64) -> TmuxTransactionMarker {
        TmuxTransactionMarker(timestamp: 10, commandNumber: commandNumber, flags: 0)
    }

    private var endpoint: SSHEndpoint {
        SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k"))
    }
}
