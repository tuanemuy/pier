@testable import Pier
import PierApplication
import XCTest

final class UserFacingErrorTests: XCTestCase {
    func testMapsSessionCommandErrorsToActionableCopy() {
        XCTAssertEqual(
            UserFacingError.message(for: SessionCommandError.disconnected),
            "tmuxに接続されていません。再接続してからお試しください。"
        )
        XCTAssertEqual(
            UserFacingError.message(for: SessionCommandError.staleGeneration),
            "接続が切り替わったため操作を完了できませんでした。もう一度お試しください。"
        )
    }
}
