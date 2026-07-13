import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import PierDomain
import PierSupport

enum ExternalSigningKey {
    static func make(capability: SSHSigningCapability) throws -> NIOSSHPrivateKey {
        switch capability.kind {
        case .ed25519:
            let body = try publicKeyBody(capability.publicKey, algorithm: Ed25519PrivateKey.keyPrefix)
            _ = try Ed25519PublicKey.validated(body: body)
            return NIOSSHPrivateKey(custom: Ed25519PrivateKey(body: body, capability: capability))
        case .secureEnclaveP256:
            let body = try publicKeyBody(capability.publicKey, algorithm: P256PrivateKey.keyPrefix)
            _ = try P256PublicKey.validated(body: body)
            return NIOSSHPrivateKey(custom: P256PrivateKey(body: body, capability: capability))
        }
    }

    private static func publicKeyBody(_ value: String, algorithm: String) throws -> Data {
        let components = value.split(separator: " ", maxSplits: 2)
        guard components.count >= 2, components[0] == Substring(algorithm),
              let blob = Data(base64Encoded: String(components[1]))
        else { throw PierError.authentication("Invalid OpenSSH public key") }
        var algorithmBuffer = byteBuffer(blob)
        guard let encodedAlgorithm = try? readSSHString(from: &algorithmBuffer),
              encodedAlgorithm.elementsEqual(algorithm.utf8)
        else { throw PierError.authentication("Invalid OpenSSH public key") }
        return Data(algorithmBuffer.readableBytesView)
    }

    struct Ed25519PrivateKey: NIOSSHPrivateKeyProtocol {
        static let keyPrefix = "ssh-ed25519"
        let body: Data
        let capability: SSHSigningCapability
        var publicKey: NIOSSHPublicKeyProtocol {
            Ed25519PublicKey(body: body)
        }

        func signature(for data: some DataProtocol) throws -> NIOSSHSignatureProtocol {
            let raw = try Data(capability.sign(Array(data)))
            guard raw.count == 64 else { throw invalidSignature() }
            return Ed25519Signature(rawRepresentation: raw)
        }
    }

    struct P256PrivateKey: NIOSSHPrivateKeyProtocol {
        static let keyPrefix = "ecdsa-sha2-nistp256"
        let body: Data
        let capability: SSHSigningCapability
        var publicKey: NIOSSHPublicKeyProtocol {
            P256PublicKey(body: body)
        }

        func signature(for data: some DataProtocol) throws -> NIOSSHSignatureProtocol {
            let der = try Data(capability.sign(Array(data)))
            let raw = try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
            return P256Signature(rawRepresentation: raw)
        }
    }

    struct Ed25519PublicKey: NIOSSHPublicKeyProtocol {
        static let publicKeyPrefix = "ssh-ed25519"
        let body: Data
        var rawRepresentation: Data {
            body
        }

        func isValidSignature(_ signature: NIOSSHSignatureProtocol, for data: some DataProtocol) -> Bool {
            guard let signature = signature as? Ed25519Signature,
                  let keyData = try? Self.publicKeyData(body),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            else { return false }
            return key.isValidSignature(signature.rawRepresentation, for: data)
        }

        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeData(body)
        }

        static func read(from buffer: inout ByteBuffer) throws -> Self {
            let body = Data(buffer.readableBytesView)
            let key = try validated(body: body)
            buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
            return key
        }

        static func validated(body: Data) throws -> Self {
            _ = try publicKeyData(body)
            return Self(body: body)
        }

        private static func publicKeyData(_ body: Data) throws -> Data {
            do {
                var buffer = byteBuffer(body)
                let key = try readSSHString(from: &buffer)
                guard key.count == 32, buffer.readableBytes == 0 else { throw invalidKey() }
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: key)
                return key
            } catch {
                throw invalidKey()
            }
        }
    }

    struct P256PublicKey: NIOSSHPublicKeyProtocol {
        static let publicKeyPrefix = "ecdsa-sha2-nistp256"
        let body: Data
        var rawRepresentation: Data {
            body
        }

        func isValidSignature(_ signature: NIOSSHSignatureProtocol, for data: some DataProtocol) -> Bool {
            guard let signature = signature as? P256Signature,
                  let point = try? Self.publicKeyPoint(body),
                  let key = try? P256.Signing.PublicKey(x963Representation: point),
                  let cryptoSignature = try? P256.Signing.ECDSASignature(
                      rawRepresentation: signature.rawRepresentation
                  )
            else { return false }
            return key.isValidSignature(cryptoSignature, for: data)
        }

        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeData(body)
        }

        static func read(from buffer: inout ByteBuffer) throws -> Self {
            let body = Data(buffer.readableBytesView)
            let key = try validated(body: body)
            buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
            return key
        }

        static func validated(body: Data) throws -> Self {
            _ = try publicKeyPoint(body)
            return Self(body: body)
        }

        private static func publicKeyPoint(_ body: Data) throws -> Data {
            do {
                var buffer = byteBuffer(body)
                let curve = try readSSHString(from: &buffer)
                let point = try readSSHString(from: &buffer)
                guard curve.elementsEqual("nistp256".utf8),
                      point.count == 65, point.first == 4, buffer.readableBytes == 0
                else { throw invalidKey() }
                _ = try P256.Signing.PublicKey(x963Representation: point)
                return point
            } catch {
                throw invalidKey()
            }
        }
    }

    struct Ed25519Signature: NIOSSHSignatureProtocol {
        static let signaturePrefix = "ssh-ed25519"
        let rawRepresentation: Data
        func write(to buffer: inout ByteBuffer) -> Int {
            writeSSHString(rawRepresentation, to: &buffer)
        }

        static func read(from buffer: inout ByteBuffer) throws -> Self {
            let raw = try readSSHString(from: &buffer)
            guard raw.count == 64, buffer.readableBytes == 0 else { throw invalidSignature() }
            return Self(rawRepresentation: raw)
        }
    }

    struct P256Signature: NIOSSHSignatureProtocol {
        static let signaturePrefix = "ecdsa-sha2-nistp256"
        let rawRepresentation: Data
        func write(to buffer: inout ByteBuffer) -> Int {
            let half = rawRepresentation.count / 2
            let payload = sshMPInt(rawRepresentation.prefix(half)) + sshMPInt(rawRepresentation.suffix(half))
            return writeSSHString(payload, to: &buffer)
        }

        static func read(from buffer: inout ByteBuffer) throws -> Self {
            var payload = try byteBuffer(readSSHString(from: &buffer))
            guard buffer.readableBytes == 0 else { throw invalidSignature() }
            let first = try readPositiveMPInt(from: &payload)
            let second = try readPositiveMPInt(from: &payload)
            guard payload.readableBytes == 0 else { throw invalidSignature() }
            let raw = try fixedWidth(first) + fixedWidth(second)
            _ = try P256.Signing.ECDSASignature(rawRepresentation: raw)
            return Self(rawRepresentation: raw)
        }
    }

    private static func writeSSHString(_ data: Data, to buffer: inout ByteBuffer) -> Int {
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { buffer.writeBytes($0) } + buffer.writeData(data)
    }

    private static func readSSHString(from buffer: inout ByteBuffer) throws -> Data {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readData(length: Int(length))
        else { throw PierError.authentication("Invalid SSH signature encoding") }
        return data
    }

    private static func readPositiveMPInt(from buffer: inout ByteBuffer) throws -> Data {
        let value = try readSSHString(from: &buffer)
        guard let first = value.first, first & 0x80 == 0 else { throw invalidSignature() }
        if value.count > 1, first == 0, value[value.index(after: value.startIndex)] & 0x80 == 0 {
            throw invalidSignature()
        }
        return first == 0 ? Data(value.dropFirst()) : value
    }

    private static func fixedWidth(_ value: Data) throws -> Data {
        guard !value.isEmpty, value.count <= 32 else { throw invalidSignature() }
        return Data(repeating: 0, count: 32 - value.count) + value
    }

    private static func byteBuffer(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeData(data)
        return buffer
    }

    private static func invalidKey() -> PierError {
        .authentication("Invalid SSH public key encoding")
    }

    private static func invalidSignature() -> PierError {
        .authentication("Invalid SSH signature encoding")
    }

    private static func sshMPInt(_ bytes: some DataProtocol) -> Data {
        var value = Data(bytes).drop { $0 == 0 }
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: value.startIndex) }
        var length = UInt32(value.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + value
    }
}
