import Foundation
import PierApplication
import PierDomain
import XCTest

final class TmuxGatewayGenerationTests: XCTestCase {
    func testStalledOldRendererCannotDispatchRemainingLinesIntoReconnectedGeneration() async throws {
        let transport = FakeTransport()
        let renderer = StallingRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        await transport.yield("%output %1 old\n%begin 90 90 0\n%end 90 90 0\n")
        await renderer.waitUntilStalled()
        await gateway.disconnect()
        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        let command = Task { try await gateway.command("display-message current") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await renderer.resume()
        await transport.yield("%begin 10 1 0\ncurrent\n%end 10 1 0\n")

        let response = try await command.value
        XCTAssertEqual(response, ["current"])
        let state = await gateway.state
        XCTAssertEqual(state, .connected)
    }

    func testNaturalExitInvalidatesTrailingOutputInSameChunk() async throws {
        let transport = FakeTransport()
        let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        try await gateway.connect(endpoint: endpoint, sessionName: "main")

        await transport.yield("%exit done\n%output %1 trailing\n")
        while await gateway.state != .disconnected {
            await Task.yield()
        }

        let output = await renderer.output
        XCTAssertTrue(output.isEmpty)
    }

    func testStalledOldRendererFeedCannotCommitAfterNewGenerationCapture() async throws {
        let transport = FakeTransport()
        let renderer = StallingRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        await transport.yield("%output %1 old\n")
        await renderer.waitUntilStalled()

        await gateway.disconnect()
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        let targetPaneID = try paneID("%1")
        let capture = Task { try await gateway.capturePane(targetPaneID) }
        while await transport.sent.isEmpty {
            await Task.yield()
        }
        await transport.yield("%begin 20 20 0\nnew\n%end 20 20 0\n")
        _ = try await capture.value
        await renderer.resume()

        let output = await renderer.output[targetPaneID]
        XCTAssertEqual(output, Data("new\n".utf8))
    }

    func testProtocolTerminalInvalidatesTrailingOutputInSameChunk() async throws {
        let transport = FakeTransport()
        let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        let command = Task { try await gateway.command("first") }
        while await transport.sent.isEmpty {
            await Task.yield()
        }

        await transport.yield("%begin 10 1 0\n%end 10 2 0\n%output %1 trailing\n")
        do {
            _ = try await command.value
            XCTFail("Expected protocol terminal")
        } catch {
            XCTAssertTrue(error is TmuxCommandProtocolError)
        }

        let output = await renderer.output
        XCTAssertTrue(output.isEmpty)
    }

    func testStaleRemoveUsesExpectedGenerationAndCannotDeleteCurrentOutput() async throws {
        let transport = FakeTransport()
        let renderer = FakeRenderer()
        let gateway = TmuxGateway(transport: transport, renderer: renderer)
        let oldGeneration = try await gateway.connect(endpoint: endpoint, sessionName: "main")
        await gateway.disconnect()
        try await gateway.connect(endpoint: endpoint, sessionName: "main")
        let targetPaneID = try paneID("%1")
        await transport.yield("%output %1 current\n")
        while await renderer.output[targetPaneID] == nil {
            await Task.yield()
        }

        await gateway.removeRenderedPane(targetPaneID, generation: oldGeneration)

        let output = await renderer.output[targetPaneID]
        let removed = await renderer.removed
        XCTAssertEqual(output, Data("current".utf8))
        XCTAssertFalse(removed.contains(targetPaneID))
    }

    private var endpoint: SSHEndpoint {
        SSHEndpoint(address: "h", username: "u", keyID: KeyID(rawValue: "k"))
    }
}

private actor StallingRenderer: PaneRendererPort {
    private var stallContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var stalled = false
    private var generation: TmuxConnectionGeneration?
    private var shouldStall = true
    private(set) var output: [PaneID: Data] = [:]

    func activate(generation: TmuxConnectionGeneration) {
        if self.generation == nil || generation.rawValue >= self.generation?.rawValue ?? 0 {
            self.generation = generation
        }
    }

    func feed(_ data: sending Data, to paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == self.generation else { return }
        if shouldStall {
            shouldStall = false
            stalled = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { stallContinuation = $0 }
        }
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
    }

    func waitUntilStalled() async {
        if stalled { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func resume() {
        stallContinuation?.resume()
        stallContinuation = nil
    }
}
