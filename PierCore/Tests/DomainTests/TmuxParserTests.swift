import Foundation
import PierDomain
import XCTest

final class TmuxParserTests: XCTestCase {
    func testParsesFirstControlModeLineInsideDCSWrapper() throws {
        let result = TmuxParser.parse("shell prompt \u{1B}P1000p%begin 10 20 0")

        XCTAssertEqual(try result.get(), .begin(timestamp: 10, commandNumber: 20, flags: 0))
    }

    func testParsesTransactionMarkers() throws {
        XCTAssertEqual(
            try TmuxParser.parse("%begin 1710000000 7 0").get(),
            .begin(timestamp: 1_710_000_000, commandNumber: 7, flags: 0)
        )
        XCTAssertEqual(
            try TmuxParser.parse("%end 1710000000 7 0").get(),
            .end(timestamp: 1_710_000_000, commandNumber: 7, flags: 0)
        )
    }

    func testDecodesOutputOctalEscapesWithoutChangingUTF8() throws {
        let message = try TmuxParser.parse("%output %3 hello\\040world\\015\\012日本語").get()
        XCTAssertEqual(message, try .output(paneID: paneID("%3"), data: Data("hello world\r\n日本語".utf8)))
    }

    func testPreservesInvalidUTF8BytesInPaneOutput() throws {
        var line = Data("%output %3 raw:".utf8)
        line.append(contentsOf: [0xFF, 0x5C, 0x30, 0x34, 0x30, 0x80])

        XCTAssertEqual(
            try TmuxParser.parse(line).get(),
            try .output(paneID: paneID("%3"), data: Data([0x72, 0x61, 0x77, 0x3A, 0xFF, 0x20, 0x80]))
        )
    }

    func testReplacesInvalidUTF8InCommandResponseWithoutRejectingStream() throws {
        XCTAssertEqual(
            try TmuxParser.parse(Data([0x66, 0x6F, 0x80])).get(),
            .responseLine("fo\u{FFFD}")
        )
    }

    func testRejectsInvalidUTF8InControlStructure() {
        var line = Data("%window-renamed @1 ".utf8)
        line.append(0xFF)

        XCTAssertEqual(TmuxParser.parse(line), .failure(.invalidUTF8))
    }

    func testRejectsTruncatedEscape() {
        XCTAssertThrowsError(try TmuxParser.parse("%output %1 bad\\01").get())
    }

    func testPreservesUnknownNotifications() throws {
        XCTAssertEqual(
            try TmuxParser.parse("%client-session-changed /dev/ttys001 $2 foo").get(),
            .unknown("%client-session-changed /dev/ttys001 $2 foo")
        )
    }

    func testParsesAttachSessionTranscriptFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/attach-session.txt")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let messages = try lines.map { try TmuxParser.parse($0).get() }
        XCTAssertTrue(try messages.contains(.sessionChanged(sessionID: sessionID("$1"), name: "main")))
        XCTAssertTrue(try messages.contains(.output(paneID: paneID("%3"), data: Data("ready 日本語\r\n".utf8))))
    }
}
