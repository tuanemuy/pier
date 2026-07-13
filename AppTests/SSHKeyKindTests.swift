import KeychainAdapter
import PierDomain
import XCTest

final class SSHKeyKindTests: XCTestCase {
    func testGeneratesBothSupportedSSHKeyKinds() async throws {
        let store = SecureEnclaveKeyStore(service: "app.pier.tests.\(UUID().uuidString)")
        let p256 = try await store.generate(name: "P-256", kind: .secureEnclaveP256)
        let ed25519 = try await store.generate(name: "Ed25519", kind: .ed25519)

        XCTAssertEqual(p256.kind, .secureEnclaveP256)
        XCTAssertTrue(p256.publicKey.hasPrefix("ecdsa-sha2-nistp256 "))
        XCTAssertEqual(ed25519.kind, .ed25519)
        XCTAssertTrue(ed25519.publicKey.hasPrefix("ssh-ed25519 "))

        let payload = Array("pier".utf8)
        let p256Signature = try await store.sign(payload, using: p256.id)
        let ed25519Signature = try await store.sign(payload, using: ed25519.id)
        XCTAssertFalse(p256Signature.isEmpty)
        XCTAssertFalse(ed25519Signature.isEmpty)

        try await store.rename(id: ed25519.id, name: "Renamed")
        let renamed = try await store.all().first { $0.id == ed25519.id }
        XCTAssertEqual(renamed?.name, "Renamed")
        XCTAssertEqual(renamed?.kind, .ed25519)

        try await store.remove(id: p256.id)
        try await store.remove(id: ed25519.id)
    }
}
