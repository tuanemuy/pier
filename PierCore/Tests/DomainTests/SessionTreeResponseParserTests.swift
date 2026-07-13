import PierDomain
import XCTest

final class SessionTreeResponseParserTests: XCTestCase {
    private let delimiter = SessionTreeRecordFormat.delimiter

    func testFormatUsesLiteralUnitSeparatorContract() {
        XCTAssertEqual(SessionTreeRecordFormat.delimiter, "\u{1F}")
        XCTAssertEqual(
            SessionTreeRecordFormat.windows,
            [
                "#{session_id}", "#{session_name}", "#{window_id}",
                "#{window_index}", "#{window_name}", "#{window_active}"
            ].joined(separator: delimiter)
        )
        XCTAssertEqual(
            SessionTreeRecordFormat.panes,
            [
                "#{session_id}", "#{window_id}", "#{pane_id}", "#{pane_left}", "#{pane_top}",
                "#{pane_title}", "#{pane_current_command}", "#{pane_current_path}",
                "#{pane_width}", "#{pane_height}", "#{alternate_on}", "#{pane_active}"
            ].joined(separator: delimiter)
        )
    }

    func testBuildsSessionWindowPaneTree() throws {
        let windowLines = [
            ["$2", "work", "@3", "1", "logs", "0"].joined(separator: delimiter),
            ["$1", "main", "@2", "1", "server", "0"].joined(separator: delimiter),
            ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        ]
        let paneLines = [
            ["$1", "@1", "%1", "0", "0", "code", "zsh", "/home/me/project", "80", "24", "0", "1"]
                .joined(separator: delimiter),
            ["$1", "@1", "%2", "80", "0", "tests", "swift", "/home/me/project", "1", "0"]
                .joined(separator: delimiter)
        ]

        let sessions = try SessionTreeResponseParser.parse(windowLines: windowLines, paneLines: paneLines)

        XCTAssertEqual(sessions.map(\.name), ["main", "work"])
        XCTAssertEqual(sessions[0].activeWindowID, try windowID("@1"))
        XCTAssertEqual(sessions[0].windows.map(\.id), try [windowID("@1"), windowID("@2")])
        XCTAssertEqual(sessions[0].windows[0].activePaneID, try paneID("%1"))
        XCTAssertEqual(sessions[0].windows[0].panes[0].currentPath, "/home/me/project")
        XCTAssertEqual(sessions[0].windows[0].panes[0].width, 80)
        XCTAssertEqual(sessions[0].windows[0].panes[0].height, 24)
        XCTAssertTrue(sessions[0].windows[0].panes[1].isAlternateScreen)
    }

    func testEmptyResponsesProduceValidEmptyTree() throws {
        XCTAssertEqual(try SessionTreeResponseParser.parse(windowLines: [], paneLines: []), [])
    }

    func testMalformedWindowRecordReturnsTypedErrorInsteadOfEmptyTree() {
        let malformed = ["$1", "main", "@1", "not-an-index", "editor", "1"].joined(separator: delimiter)

        XCTAssertThrowsError(try SessionTreeResponseParser.parse(windowLines: [malformed], paneLines: [])) { error in
            XCTAssertEqual(
                error as? SessionTreeParseError,
                .malformedRecord(kind: .window, lineNumber: 1, line: malformed)
            )
        }
    }

    func testMalformedPaneRecordReturnsCompleteTypedError() {
        let window = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let validPane = ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/home/me", "0", "1"]
            .joined(separator: delimiter)
        let malformed = ["$1", "@1", "%2", "not-an-x", "0", "tests", "swift", "/home/me", "0", "0"]
            .joined(separator: delimiter)

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [window], paneLines: [validPane, malformed])
        ) { error in
            XCTAssertEqual(
                error as? SessionTreeParseError,
                .malformedRecord(kind: .pane, lineNumber: 2, line: malformed)
            )
        }
    }

    func testDuplicateWindowReturnsTypedError() throws {
        let first = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let duplicate = ["$1", "main", "@1", "1", "logs", "0"].joined(separator: delimiter)
        let expected = try SessionTreeParseError.duplicateWindow(windowID("@1"))

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [first, duplicate], paneLines: [])
        ) { error in
            XCTAssertEqual(error as? SessionTreeParseError, expected)
        }
    }

    func testDuplicatePaneReturnsTypedError() throws {
        let window = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let first = ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/home/me", "0", "1"]
            .joined(separator: delimiter)
        let duplicate = ["$1", "@1", "%1", "80", "0", "tests", "swift", "/home/me", "0", "0"]
            .joined(separator: delimiter)
        let expected = try SessionTreeParseError.duplicatePane(paneID("%1"))

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [window], paneLines: [first, duplicate])
        ) { error in
            XCTAssertEqual(error as? SessionTreeParseError, expected)
        }
    }

    func testInconsistentSessionNameReturnsTypedError() throws {
        let first = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let inconsistent = ["$1", "renamed", "@2", "1", "logs", "0"].joined(separator: delimiter)
        let expected = try SessionTreeParseError.inconsistentSessionName(sessionID("$1"))

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [first, inconsistent], paneLines: [])
        ) { error in
            XCTAssertEqual(error as? SessionTreeParseError, expected)
        }
    }

    func testPaneSessionMismatchReturnsTypedError() throws {
        let window = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let pane = ["$2", "@1", "%1", "0", "0", "shell", "zsh", "/home/me", "0", "1"]
            .joined(separator: delimiter)
        let expected = try SessionTreeParseError.paneSessionMismatch(
            paneID: paneID("%1"),
            expected: sessionID("$1"),
            actual: sessionID("$2")
        )

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [window], paneLines: [pane])
        ) { error in
            XCTAssertEqual(
                error as? SessionTreeParseError,
                expected
            )
        }
    }

    func testPaneWithoutMatchingWindowReturnsTypedError() throws {
        let pane = ["$1", "@9", "%1", "0", "0", "shell", "zsh", "/home/me", "0", "1"]
            .joined(separator: delimiter)
        let expected = try SessionTreeParseError.paneWithoutWindow(
            paneID: paneID("%1"),
            windowID: windowID("@9")
        )

        XCTAssertThrowsError(try SessionTreeResponseParser.parse(windowLines: [], paneLines: [pane])) { error in
            XCTAssertEqual(
                error as? SessionTreeParseError,
                expected
            )
        }
    }

    func testRejectsIdentifierWithWrongTmuxKind() {
        let malformed = ["%1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)

        XCTAssertThrowsError(try SessionTreeResponseParser.parse(windowLines: [malformed], paneLines: [])) { error in
            XCTAssertEqual(
                error as? SessionTreeParseError,
                .malformedRecord(kind: .window, lineNumber: 1, line: malformed)
            )
        }
    }

    func testRejectsIdentifierWithoutNumericSuffix() {
        let malformed = ["$main", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)

        XCTAssertThrowsError(try SessionTreeResponseParser.parse(windowLines: [malformed], paneLines: [])) { error in
            XCTAssertEqual(
                error as? SessionTreeParseError,
                .malformedRecord(kind: .window, lineNumber: 1, line: malformed)
            )
        }
    }

    func testMultipleActiveWindowsReturnsTypedError() throws {
        let first = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let second = ["$1", "main", "@2", "1", "logs", "1"].joined(separator: delimiter)
        let expected = try SessionTreeParseError.multipleActiveWindows(sessionID("$1"))

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [first, second], paneLines: [])
        ) { error in
            XCTAssertEqual(error as? SessionTreeParseError, expected)
        }
    }

    func testMultipleActivePanesReturnsTypedError() throws {
        let window = ["$1", "main", "@1", "0", "editor", "1"].joined(separator: delimiter)
        let first = ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/home/me", "0", "1"]
            .joined(separator: delimiter)
        let second = ["$1", "@1", "%2", "80", "0", "tests", "swift", "/home/me", "0", "1"]
            .joined(separator: delimiter)
        let expected = try SessionTreeParseError.multipleActivePanes(windowID("@1"))

        XCTAssertThrowsError(
            try SessionTreeResponseParser.parse(windowLines: [window], paneLines: [first, second])
        ) { error in
            XCTAssertEqual(error as? SessionTreeParseError, expected)
        }
    }
}
