import CitadelAdapter
import Foundation
import PierApplication
import PierDomain
import PierSupport
import XCTest

final class PreviewTransportTests: XCTestCase {
    func testLoadsSessionTreeUsingDomainRecordFormat() async throws {
        let transport = PreviewTransport()
        let gateway = TmuxGateway(transport: transport, renderer: FakeRenderer())
        try await gateway.connect(
            endpoint: SSHEndpoint(address: "preview", username: "pier", keyID: KeyID(rawValue: "preview")),
            sessionName: "main"
        )

        let sessions = try await LoadSessionTree()(gateway: gateway)

        XCTAssertEqual(sessions.first?.name, "main")
        XCTAssertEqual(sessions.first?.windows.first?.panes.first?.currentPath, "/home/pier")
    }

    func testReconnectRoutesStartupOnlyToNewStreamGeneration() async throws {
        let transport = PreviewTransport()
        let endpoint = SSHEndpoint(address: "preview", username: "pier", keyID: KeyID(rawValue: "preview"))
        let oldGeneration = try await transport.connect(to: endpoint, command: "tmux -CC")
        let oldStream = await transport.incomingBytes(generation: oldGeneration)
        var oldIterator = oldStream.makeAsyncIterator()
        let firstStartup = try await oldIterator.next()
        XCTAssertEqual(firstStartup, Data("%begin 1 0 0\n%end 1 0 0\n".utf8))

        let newGeneration = try await transport.connect(to: endpoint, command: "tmux -CC")
        let oldCompletion = try await oldIterator.next()
        XCTAssertNil(oldCompletion)
        let newStream = await transport.incomingBytes(generation: newGeneration)
        var newIterator = newStream.makeAsyncIterator()
        let secondStartup = try await newIterator.next()
        XCTAssertEqual(secondStartup, Data("%begin 1 0 0\n%end 1 0 0\n".utf8))
    }

    func testLateStaleReaderCannotStealNewGenerationStream() async throws {
        let transport = PreviewTransport()
        let gate = SubscriptionGate()
        let endpoint = SSHEndpoint(address: "preview", username: "pier", keyID: KeyID(rawValue: "preview"))
        let staleGeneration = try await transport.connect(to: endpoint, command: "tmux -CC")
        let staleReader = Task {
            await gate.stall()
            return await transport.incomingBytes(generation: staleGeneration)
        }
        await gate.waitUntilStalled()
        staleReader.cancel()
        let currentGeneration = try await transport.connect(to: endpoint, command: "tmux -CC")
        let currentStream = await transport.incomingBytes(generation: currentGeneration)
        await gate.resume()
        let staleStream = await staleReader.value

        var staleIterator = staleStream.makeAsyncIterator()
        do {
            _ = try await staleIterator.next()
            XCTFail("Expected stale generation failure")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Stale incoming byte stream generation"))
        }

        var currentIterator = currentStream.makeAsyncIterator()
        let startup = try await currentIterator.next()
        XCTAssertEqual(startup, Data("%begin 1 0 0\n%end 1 0 0\n".utf8))
        try await transport.send(Data("capture-pane -p -t %1\n".utf8), generation: currentGeneration)
        let liveResponse = try await currentIterator.next()
        XCTAssertTrue(String(data: liveResponse ?? Data(), encoding: .utf8)?.contains("Pier preview ready") == true)
    }
}

private actor SubscriptionGate {
    private var stalled = false
    private var stalledWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func stall() async {
        stalled = true
        stalledWaiter?.resume()
        stalledWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilStalled() async {
        if stalled { return }
        await withCheckedContinuation { stalledWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
