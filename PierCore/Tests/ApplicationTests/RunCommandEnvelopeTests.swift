import Foundation
@testable import PierApplication
import XCTest

final class RunCommandEnvelopeTests: XCTestCase {
    func testWrapsPOSIXCommandWithExplicitStartAndCompletionMarkers() {
        let wrapped = ShellCommandEnvelope.wrap("echo 'test'", shell: "zsh")

        XCTAssertTrue(wrapped.hasPrefix("printf '\\033]133;C\\007'; eval "))
        XCTAssertTrue(wrapped.contains("'echo '\\''test'\\'''"))
        XCTAssertTrue(wrapped.contains("__pier_status=$?"))
        XCTAssertTrue(wrapped.contains("133;D;%d"))
    }

    func testEmptyPOSIXCommandStillEmitsCompletionMarker() {
        let wrapped = ShellCommandEnvelope.wrap("", shell: "bash")

        XCTAssertTrue(wrapped.contains("eval ''"))
        XCTAssertTrue(wrapped.contains("133;D;%d"))
    }

    func testFishEscapesSourceAndUsesFishStatus() {
        let wrapped = ShellCommandEnvelope.wrap("echo 'a\\b'", shell: "fish")

        XCTAssertTrue(wrapped.contains("eval 'echo \\'a\\\\b\\''"))
        XCTAssertTrue(wrapped.contains("set __pier_status $status"))
        XCTAssertTrue(wrapped.contains("133;D;%d"))
    }

    func testUnknownShellKeepsOriginalCommand() {
        XCTAssertEqual(ShellCommandEnvelope.wrap("echo test", shell: "nu"), "echo test")
    }
}
