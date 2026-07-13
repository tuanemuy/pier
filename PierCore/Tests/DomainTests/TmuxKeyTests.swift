import PierDomain
import XCTest

final class TmuxKeyTests: XCTestCase {
    func testAllowedKeysEncodeToTmuxTokens() {
        let cases: [(TmuxKey, String)] = [
            (.escape, "Escape"),
            (.tab, "Tab"),
            (.enter, "Enter"),
            (.arrow(.upward), "Up"),
            (.arrow(.downward), "Down"),
            (.arrow(.leftward), "Left"),
            (.arrow(.rightward), "Right"),
            (.control(.letterB), "C-b"),
            (.control(.letterC), "C-c"),
            (.control(.escape), "C-Escape"),
            (.control(.tab), "C-Tab"),
            (.control(.upward), "C-Up"),
            (.control(.downward), "C-Down"),
            (.control(.leftward), "C-Left"),
            (.control(.rightward), "C-Right")
        ]

        for (key, token) in cases {
            XCTAssertEqual(key.commandToken, token)
            XCTAssertEqual(TmuxKey.parse(token), .success(key))
        }
    }

    func testParseRejectsUnknownAndCommandSyntax() {
        let invalidTokens = [
            "",
            "Space",
            "C-a",
            "Left Right",
            "Enter; kill-server",
            "Enter\nkill-server",
            "#{session_name}"
        ]

        for token in invalidTokens {
            XCTAssertEqual(TmuxKey.parse(token), .failure(.invalidToken))
        }
    }
}
