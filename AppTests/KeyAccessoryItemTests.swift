@testable import Pier
import PierDomain
import XCTest

final class KeyAccessoryItemTests: XCTestCase {
    func testNormalAndControlledMappings() {
        let expected = [
            KeyAccessoryItem(label: "esc", normal: .escape, controlled: .control(.escape)),
            KeyAccessoryItem(label: "tab", normal: .tab, controlled: .control(.tab)),
            KeyAccessoryItem(label: "C-c", normal: .control(.letterC), controlled: .control(.letterC)),
            KeyAccessoryItem(label: "prefix", normal: .control(.letterB), controlled: .control(.letterB)),
            KeyAccessoryItem(label: "↑", normal: .arrow(.upward), controlled: .control(.upward)),
            KeyAccessoryItem(label: "↓", normal: .arrow(.downward), controlled: .control(.downward)),
            KeyAccessoryItem(label: "←", normal: .arrow(.leftward), controlled: .control(.leftward)),
            KeyAccessoryItem(label: "→", normal: .arrow(.rightward), controlled: .control(.rightward))
        ]

        XCTAssertEqual(KeyAccessoryItem.all, expected)
        for (item, mapping) in zip(KeyAccessoryItem.all, expected) {
            XCTAssertEqual(item.key(controlArmed: false), mapping.normal)
            XCTAssertEqual(item.key(controlArmed: true), mapping.controlled)
        }
    }

    func testAlreadyControlledKeysAreNotTransformedAgain() throws {
        let interrupt = try XCTUnwrap(KeyAccessoryItem.all.first { $0.label == "C-c" })
        let prefix = try XCTUnwrap(KeyAccessoryItem.all.first { $0.label == "prefix" })

        XCTAssertEqual(interrupt.key(controlArmed: false), .control(.letterC))
        XCTAssertEqual(interrupt.key(controlArmed: true), .control(.letterC))
        XCTAssertEqual(prefix.key(controlArmed: false), .control(.letterB))
        XCTAssertEqual(prefix.key(controlArmed: true), .control(.letterB))
    }
}
