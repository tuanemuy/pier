import Foundation
@testable import KeychainAdapter
import PierDomain
import PierSupport
import XCTest

final class KeychainKeyRowDecoderTests: XCTestCase {
    func testDecodesValidRow() throws {
        let stored = StoredSSHKey(name: "work", kind: .ed25519, representation: Data([1, 2, 3]))
        let row = try KeychainKeyRow(account: "key-id", data: JSONEncoder().encode(stored))

        let (id, decoded) = try KeychainKeyRowDecoder().decode(row, index: 0)

        XCTAssertEqual(id, KeyID(rawValue: "key-id"))
        XCTAssertEqual(decoded.name, "work")
        XCTAssertEqual(decoded.kind, .ed25519)
        XCTAssertEqual(decoded.representation, Data([1, 2, 3]))
    }

    func testRejectsMissingAccount() {
        assertMalformed(KeychainKeyRow(account: nil, data: Data()), index: 2)
    }

    func testRejectsMissingData() {
        assertMalformed(KeychainKeyRow(account: "key-id", data: nil), index: 3)
    }

    func testRejectsInvalidJSON() {
        assertMalformed(KeychainKeyRow(account: "key-id", data: Data("invalid".utf8)), index: 4)
    }

    private func assertMalformed(_ row: KeychainKeyRow, index: Int) {
        XCTAssertThrowsError(try KeychainKeyRowDecoder().decode(row, index: index)) { error in
            XCTAssertEqual(error as? PierError, .authentication("Malformed Keychain key row at index \(index)"))
        }
    }
}
