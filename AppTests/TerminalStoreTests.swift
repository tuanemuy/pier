import CitadelAdapter
@testable import Pier
import PierApplication
import PierDomain
import XCTest

final class TerminalStoreTests: XCTestCase {
    func testStaleGenerationCannotResetOrFeedCurrentTerminal() async throws {
        let store = TerminalStore()
        let gateway = TmuxGateway(transport: PreviewTransport(), renderer: store)
        let endpoint = SSHEndpoint(
            address: "preview",
            username: "pier",
            keyID: KeyID(rawValue: "preview-key")
        )
        let staleGeneration = try await gateway.connect(endpoint: endpoint, sessionName: "main")
        await gateway.disconnect()
        let currentGeneration = try await gateway.connect(endpoint: endpoint, sessionName: "main")
        guard case let .success(paneID) = PaneID.parse("%3") else {
            return XCTFail("Expected valid pane identifier")
        }
        await store.feed(Data("before".utf8), to: paneID, generation: currentGeneration)
        let stream = await store.stream(for: paneID)
        var iterator = stream.makeAsyncIterator()

        await store.activate(generation: staleGeneration)
        await store.feed(Data("stale".utf8), to: paneID, generation: staleGeneration)
        await store.reset(paneID: paneID, generation: staleGeneration)
        await store.remove(paneID: paneID, generation: staleGeneration)
        await store.feed(Data("current".utf8), to: paneID, generation: currentGeneration)

        guard case let .data(bufferedData)? = await iterator.next() else {
            return XCTFail("Expected buffered current generation data")
        }
        XCTAssertEqual(String(data: bufferedData, encoding: .utf8), "before")
        guard case let .data(data)? = await iterator.next() else {
            return XCTFail("Expected current generation data")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "current")
        await gateway.disconnect()
    }

    func testResetClearsBufferedDataAndNotifiesActiveTerminal() async {
        let store = TerminalStore()
        guard case let .success(paneID) = PaneID.parse("%1") else {
            return XCTFail("Expected valid pane identifier")
        }
        let stream = await store.stream(for: paneID)
        var iterator = stream.makeAsyncIterator()

        await store.feed(Data("before".utf8), to: paneID)
        guard case let .data(data)? = await iterator.next() else {
            return XCTFail("Expected terminal data")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "before")

        await store.reset(paneID: paneID)
        guard case .reset? = await iterator.next() else {
            return XCTFail("Expected terminal reset")
        }

        let replay = await store.stream(for: paneID)
        var replayIterator = replay.makeAsyncIterator()
        await store.feed(Data("after".utf8), to: paneID)
        guard case let .data(replayedData)? = await replayIterator.next() else {
            return XCTFail("Expected terminal data after reset")
        }
        XCTAssertEqual(String(data: replayedData, encoding: .utf8), "after")
    }

    func testRemoveFinishesSubscribersAndDropsBufferedData() async {
        let store = TerminalStore()
        guard case let .success(paneID) = PaneID.parse("%2") else {
            return XCTFail("Expected valid pane identifier")
        }
        await store.feed(Data("discarded".utf8), to: paneID)
        let stream = await store.stream(for: paneID)
        var iterator = stream.makeAsyncIterator()

        guard case .data? = await iterator.next() else {
            return XCTFail("Expected buffered terminal data")
        }
        await store.remove(paneID: paneID)
        let removedEvent = await iterator.next()
        XCTAssertNil(removedEvent)

        let replacement = await store.stream(for: paneID)
        var replacementIterator = replacement.makeAsyncIterator()
        await store.feed(Data("replacement".utf8), to: paneID)
        guard case let .data(replacementData)? = await replacementIterator.next() else {
            return XCTFail("Expected replacement terminal data")
        }
        XCTAssertEqual(String(data: replacementData, encoding: .utf8), "replacement")
    }
}
