@testable import Pier
import SwiftTerm
import UIKit
import XCTest

final class TerminalWideGlyphTests: XCTestCase {
    func testJapaneseGlyphOccupiesTwoTerminalColumns() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: "A日B")
        XCTAssertEqual(terminal.getCursorLocation().x, 4)
    }

    func testBundledMonospaceFontIsRegistered() {
        XCTAssertNotNil(Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf"))
        XCTAssertNotNil(UIFont(name: "JetBrainsMono-Regular", size: 14))
    }
}

private final class Delegate: TerminalDelegate {
    func send(source _: Terminal, data _: ArraySlice<UInt8>) {}
}
