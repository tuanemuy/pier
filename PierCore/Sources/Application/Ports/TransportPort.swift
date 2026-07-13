import Foundation
import PierDomain

public struct SSHEndpoint: Equatable, Sendable {
    public let address: String
    public let username: String
    public let keyID: KeyID
    public init(address: String, username: String, keyID: KeyID) {
        self.address = address; self.username = username; self.keyID = keyID
    }
}

public struct TransportConnectionGeneration: Equatable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public protocol TransportPort: Sendable {
    func execute(_ command: String, at endpoint: SSHEndpoint) async throws -> Data
    func executeIdempotent(_ command: String, at endpoint: SSHEndpoint) async throws -> Data
    func connect(to endpoint: SSHEndpoint, command: String) async throws -> TransportConnectionGeneration
    func send(_ data: sending Data, generation: TransportConnectionGeneration) async throws
    func incomingBytes(generation: TransportConnectionGeneration) async -> AsyncThrowingStream<Data, Error>
    func disconnect() async
}

public protocol FileTransferPort: Sendable {
    func read(path: String) async throws -> Data
    func write(_ data: sending Data, path: String) async throws
}

public protocol PaneRendererPort: Sendable {
    func activate(generation: TmuxConnectionGeneration) async
    func feed(_ data: sending Data, to paneID: PaneID, generation: TmuxConnectionGeneration) async
    func reset(paneID: PaneID, generation: TmuxConnectionGeneration) async
    func remove(paneID: PaneID, generation: TmuxConnectionGeneration) async
}

public protocol Clock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public protocol IdentifierGenerator: Sendable {
    func makeUUID() -> UUID
}

public protocol PierLogger: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

public enum LogLevel: Sendable { case debug, info, warning, error }

public struct NullLogger: PierLogger {
    public init() {}
    public func log(_: LogLevel, _: String) {}
}
