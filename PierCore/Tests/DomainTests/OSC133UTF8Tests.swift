import Foundation
import PierDomain
import XCTest

final class OSC133UTF8Tests: XCTestCase {
    func testJapaneseAndEmojiSurviveEveryChunkBoundary() {
        for value in ["日本語", "🙂"] {
            let bytes = Data(value.utf8)
            for split in 0 ... bytes.count {
                var parser = OSC133Parser()
                var events = parser.consume(Self.commandStarted)
                events += parser.consume(Data(bytes.prefix(split)))
                events += parser.consume(Data(bytes.dropFirst(split)))
                events += parser.consume(Self.commandFinished)
                XCTAssertEqual(Self.output(from: events), value, "split=\(split), value=\(value)")
            }
        }
    }

    func testScalarsAndAdjacentMarkersSurviveSingleByteChunks() {
        let expected = "前🙂後"
        let stream = Self.commandStarted + Data("前".utf8) + Self.promptStarted +
            Data("🙂後".utf8) + Self.commandFinished
        var parser = OSC133Parser()
        var events: [OSC133Parser.Event] = []
        for byte in stream {
            events += parser.consume(Data([byte]))
        }
        XCTAssertEqual(Self.output(from: events), expected)
        XCTAssertTrue(events.contains(.promptStarted))
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 0)))
    }

    func testIncompleteScalarAtMarkerBoundaryUsesReplacementCharacter() {
        var parser = OSC133Parser()
        var events = parser.consume(Self.commandStarted)
        events += parser.consume(Data([0xF0, 0x9F]) + Self.promptStarted)
        events += parser.consume(Data([0x99, 0x82]) + Self.commandFinished)
        XCTAssertEqual(Self.output(from: events), "���")
    }

    func testInvalidTerminalBytesUseExplicitReplacementPolicy() {
        let invalid = Data([0x66, 0x80, 0x67, 0xF5])
        let expected = "f�g�"
        XCTAssertEqual(TerminalText.plain(invalid), expected)

        var parser = OSC133Parser()
        var events = parser.consume(Self.commandStarted)
        events += parser.consume(invalid)
        events += parser.consume(Self.commandFinished)
        XCTAssertEqual(Self.output(from: events), expected)
    }

    func testRepeatedChunksDoNotDuplicateOrLosePendingBytes() {
        let value = "界🚢界🚢"
        var parser = OSC133Parser()
        var events = parser.consume(Self.commandStarted)
        for _ in 0 ..< 3 {
            events += parser.consume(Data())
        }
        for byte in value.utf8 {
            events += parser.consume(Data([byte]))
            events += parser.consume(Data())
        }
        events += parser.consume(Self.commandFinished)
        XCTAssertEqual(Self.output(from: events), value)
    }

    private static let commandStarted = Data("\u{1B}]133;C\u{7}".utf8)
    private static let promptStarted = Data("\u{1B}]133;A\u{7}".utf8)
    private static let commandFinished = Data("\u{1B}]133;D;0\u{7}".utf8)

    private static func output(from events: [OSC133Parser.Event]) -> String {
        events.reduce(into: "") { result, event in
            if case let .output(value) = event { result += value }
        }
    }
}
