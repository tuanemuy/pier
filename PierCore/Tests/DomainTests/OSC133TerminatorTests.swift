import Foundation
import PierDomain
import XCTest

final class OSC133TerminatorTests: XCTestCase {
    func testSTBeforeBELUsesEarlierST() {
        let stream = Self.marker("C", terminator: Self.stringTerminator) + Data("left\u{7}right".utf8) +
            Self.marker("D;0", terminator: Self.bell)
        let events = Self.consume(stream)
        XCTAssertEqual(Self.output(from: events), "left\u{7}right")
        XCTAssertTrue(events.contains(.commandStarted))
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 0)))
    }

    func testBELBeforeSTUsesEarlierBEL() {
        let stream = Self.marker("C", terminator: Self.bell) + Data("left".utf8) + Self.stringTerminator +
            Data("right".utf8) + Self.marker("D;0", terminator: Self.stringTerminator)
        let events = Self.consume(stream)
        XCTAssertEqual(Self.output(from: events), "leftright")
        XCTAssertTrue(events.contains(.commandStarted))
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 0)))
    }

    func testUnrelatedESCBeforeSTDoesNotHideLaterST() {
        let unknown = Data("\u{1B}]133;X\u{1B}A".utf8) + Self.stringTerminator
        let events = Self.consume(unknown + Self.marker("C", terminator: Self.bell))
        XCTAssertEqual(events, [.commandStarted])
    }

    func testMultipleUnrelatedESCsBeforeSTAreScanned() {
        let unknown = Data("\u{1B}]133;X\u{1B}A\u{1B}B\u{1B}C".utf8) + Self.stringTerminator
        let stream = unknown + Self.marker("C", terminator: Self.stringTerminator) + Data("ok".utf8) +
            Self.marker("D;0", terminator: Self.bell)
        let events = Self.consume(stream)
        XCTAssertEqual(Self.output(from: events), "ok")
        XCTAssertTrue(events.contains(.commandStarted))
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 0)))
    }

    func testSTTerminatorsSplitAcrossChunksRemainIncremental() {
        var parser = OSC133Parser()
        let start = Data("\u{1B}]133;C\u{1B}".utf8)
        XCTAssertEqual(parser.consume(start), [])
        XCTAssertEqual(parser.consume(Data("\\".utf8)), [.commandStarted])
        XCTAssertEqual(parser.consume(Data("split\u{1B}]133;D;0\u{1B}".utf8)), [.output("split")])
        XCTAssertEqual(parser.consume(Data("\\".utf8)), [.commandFinished(exitCode: 0)])
    }

    func testAdjacentMixedTerminatorsPreserveOutputAndMarkers() {
        let stream = Self.marker("C", terminator: Self.stringTerminator) + Self.marker("A", terminator: Self.bell) +
            Data("adjacent".utf8) + Self.marker("D;0", terminator: Self.stringTerminator)
        let events = Self.consume(stream)
        XCTAssertEqual(
            events,
            [.commandStarted, .promptStarted, .output("adjacent"), .commandFinished(exitCode: 0)]
        )
    }

    private static let bell = Data([0x07])
    private static let stringTerminator = Data([0x1B, 0x5C])

    private static func marker(_ payload: String, terminator: Data) -> Data {
        Data("\u{1B}]133;\(payload)".utf8) + terminator
    }

    private static func consume(_ data: Data) -> [OSC133Parser.Event] {
        var parser = OSC133Parser()
        return parser.consume(data)
    }

    private static func output(from events: [OSC133Parser.Event]) -> String {
        events.reduce(into: "") { result, event in
            if case let .output(value) = event { result += value }
        }
    }
}
