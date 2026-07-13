import PierDomain
import XCTest

final class IdentifierTests: XCTestCase {
    func testTmuxIdentifiersAcceptTheirKindAndNumericSuffix() throws {
        XCTAssertEqual(try SessionID.parse("$12").get().rawValue, "$12")
        XCTAssertEqual(try WindowID.parse("@34").get().rawValue, "@34")
        XCTAssertEqual(try PaneID.parse("%56").get().rawValue, "%56")
    }

    func testTmuxIdentifiersRejectWrongKindAndNonNumericSuffix() {
        XCTAssertEqual(SessionID.parse("%1"), .failure(.invalid))
        XCTAssertEqual(WindowID.parse("$1"), .failure(.invalid))
        XCTAssertEqual(PaneID.parse("@1"), .failure(.invalid))
        XCTAssertEqual(SessionID.parse("$main"), .failure(.invalid))
        XCTAssertEqual(SessionID.parse("$１２"), .failure(.invalid))
        XCTAssertEqual(WindowID.parse("@"), .failure(.invalid))
        XCTAssertEqual(PaneID.parse(""), .failure(.empty))
    }
}
