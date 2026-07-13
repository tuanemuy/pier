import XCTest

final class CompactWorkspaceNavigationTests: XCTestCase {
    @MainActor
    func testSidebarWindowSelectionReturnsToWorkspaceDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let host = app.buttons["host-preview"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()

        let session = app.buttons["session-main"]
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        let input = app.textFields["command-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["pane-deck"].exists)

        let sidebar = app.buttons["workspace-sidebar-button"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.tap()

        let window = app.buttons["sidebar-window-@1"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.tap()

        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["pane-deck"].exists)
    }
}
