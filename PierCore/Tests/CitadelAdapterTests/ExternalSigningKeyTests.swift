@testable import CitadelAdapter
import Crypto
import Foundation
import NIOCore
import NIOSSH
import PierDomain
import PierSupport
import XCTest

final class ExternalSigningKeyTests: XCTestCase {
    func testEd25519PublicKeyAcceptsValidSignatureAndRejectsChangedData() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let publicKey = ExternalSigningKey.Ed25519PublicKey(
            body: sshString(privateKey.publicKey.rawRepresentation)
        )
        let signature = try ExternalSigningKey.Ed25519Signature(
            rawRepresentation: privateKey.signature(for: payload)
        )

        XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("changed".utf8)))
        XCTAssertFalse(
            publicKey.isValidSignature(
                ExternalSigningKey.P256Signature(rawRepresentation: Data(repeating: 0, count: 64)),
                for: payload
            )
        )
    }

    func testP256PublicKeyAcceptsValidSignatureAndRejectsChangedData() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let body = sshString(Data("nistp256".utf8)) + sshString(privateKey.publicKey.x963Representation)
        let publicKey = ExternalSigningKey.P256PublicKey(body: body)
        let signature = try ExternalSigningKey.P256Signature(
            rawRepresentation: privateKey.signature(for: payload).rawRepresentation
        )

        XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("changed".utf8)))
    }

    func testPublicKeyReadersValidateBodiesAndConsumeValidEncoding() throws {
        let edKey = Curve25519.Signing.PrivateKey().publicKey
        var edBuffer = byteBuffer(sshString(edKey.rawRepresentation))
        XCTAssertNoThrow(try ExternalSigningKey.Ed25519PublicKey.read(from: &edBuffer))
        XCTAssertEqual(edBuffer.readableBytes, 0)

        let p256Key = P256.Signing.PrivateKey().publicKey
        let p256Body = sshString(Data("nistp256".utf8)) + sshString(p256Key.x963Representation)
        var p256Buffer = byteBuffer(p256Body)
        XCTAssertNoThrow(try ExternalSigningKey.P256PublicKey.read(from: &p256Buffer))
        XCTAssertEqual(p256Buffer.readableBytes, 0)
    }

    func testPublicKeyReadersRejectEmptyMalformedAndMismatchedBodies() {
        assertKeyReadFails(ExternalSigningKey.Ed25519PublicKey.self, data: Data())
        assertKeyReadFails(ExternalSigningKey.Ed25519PublicKey.self, data: sshString(Data(repeating: 1, count: 31)))
        let p256Key = P256.Signing.PrivateKey().publicKey
        let wrongCurve = sshString(Data("nistp384".utf8)) + sshString(p256Key.x963Representation)
        assertKeyReadFails(ExternalSigningKey.P256PublicKey.self, data: wrongCurve)
        assertKeyReadFails(ExternalSigningKey.P256PublicKey.self, data: Data())
    }

    func testOpenSSHOuterAndInnerAlgorithmMismatchIsRejected() {
        let edKey = Curve25519.Signing.PrivateKey().publicKey
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(edKey.rawRepresentation)
        let capability = SSHSigningCapability(
            kind: .secureEnclaveP256,
            publicKey: "ecdsa-sha2-nistp256 \(blob.base64EncodedString())"
        ) { _ in [] }

        XCTAssertThrowsError(try ExternalSigningKey.make(capability: capability))
    }

    func testEd25519SignatureUsesSSHStringEncoding() throws {
        let rawSignature = Data(0 ..< 64)
        let capability = SSHSigningCapability(kind: .ed25519, publicKey: "unused") { _ in
            [UInt8](rawSignature)
        }
        let key = ExternalSigningKey.Ed25519PrivateKey(body: Data(), capability: capability)

        var buffer = ByteBufferAllocator().buffer(capacity: 68)
        _ = try key.signature(for: Data("payload".utf8)).write(to: &buffer)

        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 64)
        XCTAssertEqual(buffer.readData(length: 64), rawSignature)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testP256SignatureEncodesPositiveSSHMPInts() throws {
        let privateKey = P256.Signing.PrivateKey()
        let signature = try privateKey.signature(for: Data("payload".utf8))
        let capability = SSHSigningCapability(kind: .secureEnclaveP256, publicKey: "unused") { _ in
            [UInt8](signature.derRepresentation)
        }
        let key = ExternalSigningKey.P256PrivateKey(body: Data(), capability: capability)

        var buffer = ByteBufferAllocator().buffer(capacity: 80)
        _ = try key.signature(for: Data("payload".utf8)).write(to: &buffer)

        guard let payloadLength = buffer.readInteger(as: UInt32.self),
              var payload = buffer.readSlice(length: Int(payloadLength))
        else { return XCTFail("Expected SSH signature payload") }
        let encodedR = try readSSHInteger(from: &payload)
        let encodedS = try readSSHInteger(from: &payload)
        let raw = signature.rawRepresentation
        XCTAssertEqual(normalized(encodedR), raw.prefix(32))
        XCTAssertEqual(normalized(encodedS), raw.suffix(32))
        XCTAssertEqual(payload.readableBytes, 0)
    }

    func testSignatureReadersRoundTripAndRejectMalformedEncoding() throws {
        let edRaw = Data(repeating: 7, count: 64)
        var edBuffer = byteBuffer(sshString(edRaw))
        XCTAssertEqual(try ExternalSigningKey.Ed25519Signature.read(from: &edBuffer).rawRepresentation, edRaw)

        let privateKey = P256.Signing.PrivateKey()
        let raw = try privateKey.signature(for: Data("payload".utf8)).rawRepresentation
        var encoded = ByteBufferAllocator().buffer(capacity: 80)
        _ = ExternalSigningKey.P256Signature(rawRepresentation: raw).write(to: &encoded)
        XCTAssertEqual(try ExternalSigningKey.P256Signature.read(from: &encoded).rawRepresentation, raw)

        var shortEd = byteBuffer(sshString(Data(repeating: 0, count: 63)))
        XCTAssertThrowsError(try ExternalSigningKey.Ed25519Signature.read(from: &shortEd))
        var negativeInteger = byteBuffer(sshString(sshString(Data([0x80])) + sshString(Data([1]))))
        XCTAssertThrowsError(try ExternalSigningKey.P256Signature.read(from: &negativeInteger))
        var trailingPayload = byteBuffer(sshString(sshString(Data([1])) + sshString(Data([1])) + Data([0])))
        XCTAssertThrowsError(try ExternalSigningKey.P256Signature.read(from: &trailingPayload))
    }

    private func readSSHInteger(from buffer: inout ByteBuffer) throws -> Data {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readData(length: Int(length))
        else { throw TestError.invalidEncoding }
        return data
    }

    private func normalized(_ value: Data) -> Data {
        let bytes = value.drop(while: { $0 == 0 })
        return Data(repeating: 0, count: 32 - bytes.count) + bytes
    }

    private func assertKeyReadFails<Key: NIOSSHPublicKeyProtocol>(_: Key.Type, data: Data) {
        var buffer = byteBuffer(data)
        XCTAssertThrowsError(try Key.read(from: &buffer)) { error in
            XCTAssertNotNil(error as? PierError)
        }
    }

    private func sshString(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data
    }

    private func byteBuffer(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeData(data)
        return buffer
    }

    private enum TestError: Error {
        case invalidEncoding
    }
}
