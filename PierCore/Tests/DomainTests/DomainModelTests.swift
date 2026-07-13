import Foundation
import PierDomain
import XCTest

final class DomainModelTests: XCTestCase {
    func testHostRejectsIncompleteBoundaryInput() {
        let result = Host.parse(
            id: HostID(rawValue: "h1"),
            name: "",
            address: "example.com",
            username: "me",
            keyID: KeyID(rawValue: "k1")
        )
        XCTAssertEqual(result, .failure(.missingRequiredField))
    }

    func testCommandReducerBuildsFinishedBlock() throws {
        var reducer = OSC133Reducer()
        let start = Date(timeIntervalSince1970: 100)
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        reducer.reduce(.commandStart("false"), now: start, blockID: id)
        reducer.reduce(.output("failed\n"), now: start, blockID: id)
        reducer.reduce(.commandFinished(1), now: start.addingTimeInterval(0.25), blockID: id)
        XCTAssertEqual(reducer.blocks.count, 1)
        XCTAssertEqual(reducer.blocks.first?.status, .finished(exitCode: 1))
        XCTAssertEqual(reducer.blocks.first?.outputLines, 2)
    }

    func testRollbackOnlyRemovesUnobservedRunningSubmission() throws {
        var reducer = OSC133Reducer()
        let now = Date(timeIntervalSince1970: 100)
        let emptyID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        reducer.reduce(.commandStart("not sent"), now: now, blockID: emptyID)
        reducer.rollbackSubmission(blockID: emptyID)
        XCTAssertTrue(reducer.blocks.isEmpty)

        let observedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        reducer.reduce(.commandStart("possibly sent"), now: now, blockID: observedID)
        reducer.reduce(.output("started"), now: now, blockID: observedID)
        reducer.rollbackSubmission(blockID: observedID)
        XCTAssertEqual(reducer.blocks.last?.id, observedID)
    }

    func testCommandHistoryReconcilesJournalSuffixWithoutDuplicatingCapturedOutput() {
        let now = Date(timeIntervalSince1970: 100)
        let stale = CommandBlock(
            id: UUID(),
            command: "old-command",
            output: "old-output",
            startedAt: now,
            duration: .milliseconds(10),
            status: .finished(exitCode: 0)
        )
        let first = CommandBlock(
            id: UUID(),
            command: "echo one",
            output: "one",
            startedAt: now,
            duration: .milliseconds(20),
            status: .finished(exitCode: 0)
        )
        let second = CommandBlock(
            id: UUID(),
            command: "echo two",
            output: "two",
            startedAt: now,
            duration: .milliseconds(30),
            status: .finished(exitCode: 0)
        )

        let result = CommandHistoryReconciler.reconcile(
            capture: "desktop history\n$ echo one\none\n$ echo two\ntwo",
            journal: [stale, first, second]
        )

        XCTAssertEqual(result.restoredPrefix, "desktop history\n$")
        XCTAssertEqual(result.blocks, [first, second])
    }

    func testCommandHistoryRejectsJournalFromReusedPaneID() {
        let block = CommandBlock(
            id: UUID(),
            command: "echo from old server",
            output: "old",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: .milliseconds(1),
            status: .finished(exitCode: 0)
        )

        let result = CommandHistoryReconciler.reconcile(capture: "fresh server", journal: [block])

        XCTAssertEqual(result.restoredPrefix, "fresh server")
        XCTAssertTrue(result.blocks.isEmpty)
    }

    func testRemoteFileRequiresAbsolutePath() {
        XCTAssertEqual(RemoteFile.parse(path: "relative", contents: "x"), .failure(.invalidPath))
    }

    func testOSC133ParserHandlesMarkersSplitAcrossPackets() {
        var parser = OSC133Parser()
        XCTAssertEqual(
            parser.consume(Data("\u{1B}]133;C\u{7}hello\u{1B}]13".utf8)),
            [.commandStarted, .output("hello")]
        )
        XCTAssertEqual(parser.consume(Data("3;D;0\u{7}".utf8)), [.commandFinished(exitCode: 0)])
    }

    func testTerminalTextRemovesANSIAndKeepsJapanese() {
        let data = Data("\u{1B}[31m失敗\u{1B}[0m\r\n\u{1B}]133;A\u{7}次\n".utf8)
        XCTAssertEqual(TerminalText.plain(data), "失敗\n次\n")
    }

    func testTUIStateDetectorHandlesSplitAlternateScreenSequences() {
        var detector = TUIStateDetector()
        XCTAssertFalse(detector.consume(Data("\u{1B}[?10".utf8)))
        XCTAssertTrue(detector.consume(Data("49h画面".utf8)))
        XCTAssertFalse(detector.consume(Data("\u{1B}[?1049l".utf8)))
    }

    func testTUIStateDetectorProcessesRepeatedTransitionsInByteOrder() {
        var detector = TUIStateDetector()
        let value = "\u{1B}[?1049h\u{1B}[?1049l\u{1B}[?1049h"
        XCTAssertTrue(detector.consume(Data(value.utf8)))
        XCTAssertFalse(detector.consume(Data("\u{1B}[?1049l".utf8)))
    }

    func testTUIStateDetectorProcessesRepeatedTransitionsAcrossChunks() {
        var detector = TUIStateDetector()
        XCTAssertTrue(detector.consume(Data("\u{1B}[?1049h\u{1B}[?1049".utf8)))
        XCTAssertTrue(detector.consume(Data("l\u{1B}[?1049h".utf8)))
    }
}
