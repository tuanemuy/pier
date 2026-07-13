// swiftlint:disable file_length
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import PierApplication
import PierDomain
import PierSupport

public actor CitadelTransport: TransportPort, FileTransferPort {
    public typealias SigningCapabilityProvider = @Sendable (KeyID) async throws -> SSHSigningCapability
    public typealias HostKeyVerifier = @Sendable (_ host: String, _ key: Data) async throws -> Bool
    private let keyProvider: SigningCapabilityProvider
    private let hostKeyVerifier: HostKeyVerifier
    private let retryPolicy: DriverRetryPolicy
    private var resources = SessionResourceSlot<SSHClient, TTYStdinWriter>()
    private var standardError = Data()
    private var lifecycle = TransportLifecycle()
    private var establishment: ConnectionEstablishment<SSHClient>?

    public init(keyProvider: @escaping SigningCapabilityProvider, hostKeyVerifier: @escaping HostKeyVerifier) {
        self.keyProvider = keyProvider
        self.hostKeyVerifier = hostKeyVerifier
        retryPolicy = DriverRetryPolicy(isTransient: Self.isTransient)
    }

    init(
        keyProvider: @escaping SigningCapabilityProvider,
        hostKeyVerifier: @escaping HostKeyVerifier,
        retryPolicy: DriverRetryPolicy
    ) {
        self.keyProvider = keyProvider
        self.hostKeyVerifier = hostKeyVerifier
        self.retryPolicy = retryPolicy
    }

    public func execute(_ command: String, at endpoint: SSHEndpoint) async throws -> Data {
        do {
            return try await executeOnce(command, at: endpoint)
        } catch {
            throw Self.translated(error)
        }
    }

    public func executeIdempotent(_ command: String, at endpoint: SSHEndpoint) async throws -> Data {
        let policy = retryPolicy
        do {
            return try await policy.run(safety: .idempotent) { [self] in
                try await executeOnce(command, at: endpoint)
            }
        } catch {
            throw Self.translated(error)
        }
    }

    public func connect(
        to endpoint: SSHEndpoint,
        command: String
    ) async throws -> TransportConnectionGeneration {
        #if os(macOS)
            guard #available(macOS 15, *) else {
                throw PierError.unavailable("Interactive Citadel sessions require macOS 15")
            }
        #endif
        let generation = try beginConnection()
        defer {
            lifecycle.finishConnection(generation: generation)
            if establishment?.generation == generation { establishment = nil }
        }
        await cleanupResources()
        do {
            try lifecycle.validate(generation)
        } catch {
            throw Self.translated(error)
        }
        standardError.removeAll(keepingCapacity: true)
        let client = try await establishClient(endpoint, generation: generation)
        try await validateConnection(generation, client: client)
        resources.client = client
        resources.endpoint = endpoint
        resources.inboundBytes.activate(generation: generation)
        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        resources.producer = makeStreamTask(
            client: client,
            command: command,
            ready: ready.continuation,
            generation: generation
        )
        do {
            for try await _ in ready.stream {
                do {
                    try lifecycle.validate(generation)
                } catch {
                    throw Self.translated(error)
                }
                return TransportConnectionGeneration(rawValue: generation)
            }
            throw PierError.transport("SSH exec channel ended before stdin became ready")
        } catch {
            let translatedError = Self.translated(error)
            await cleanupConnection(ownedBy: generation)
            throw translatedError
        }
    }

    public func send(_ data: sending Data, generation: TransportConnectionGeneration) async throws {
        do {
            try lifecycle.validate(generation.rawValue)
        } catch {
            throw Self.translated(error)
        }
        guard let writer = resources.writer else { throw PierError.unavailable("SSH stdin is not ready") }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await writer.write(buffer)
        } catch {
            throw Self.translated(error)
        }
    }

    public func incomingBytes(
        generation: TransportConnectionGeneration
    ) async -> AsyncThrowingStream<Data, Error> {
        do {
            try lifecycle.validate(generation.rawValue)
            return resources.inboundBytes.makeStream(generation: generation.rawValue)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: Self.translated(error)) }
        }
    }

    public func disconnect() async {
        let cleanupGeneration = lifecycle.invalidateCurrentGeneration()
        let detachedEstablishmentTask = establishment?.task
        establishment = nil
        detachedEstablishmentTask?.cancel()
        _ = await detachedEstablishmentTask?.result
        await cleanupResources()
        lifecycle.finishInvalidatedConnection(generation: cleanupGeneration)
    }

    private func cleanupConnection(ownedBy generation: UInt64) async {
        guard let cleanupGeneration = lifecycle.invalidateConnection(ownedBy: generation) else { return }
        await cleanupResources()
        lifecycle.finishInvalidatedConnection(generation: cleanupGeneration)
    }

    private func beginConnection() throws -> UInt64 {
        do {
            return try lifecycle.beginConnection()
        } catch {
            throw Self.translated(error)
        }
    }

    private func validateConnection(_ generation: UInt64, client: SSHClient) async throws {
        do {
            try lifecycle.validate(generation)
        } catch {
            try? await client.close()
            throw Self.translated(error)
        }
    }

    private func cleanupResources() async {
        var detached = resources.detach()
        detached.inboundBytes.reset()
        let producer = detached.producer
        let detachedClient = detached.client
        let cleanup = SessionResourceCleanup(
            cancelProducer: { producer?.cancel() },
            closeClient: { if let detachedClient { try? await detachedClient.close() } },
            waitForProducer: { await producer?.value }
        )
        await cleanup.run()
    }

    public func read(path: String) async throws -> Data {
        guard let client = resources.client else { throw PierError.unavailable("SSH is not connected") }
        let policy = retryPolicy
        do {
            return try await policy.run(safety: .idempotent) {
                try await client.withSFTP { sftp in
                    try await sftp.withFile(filePath: path, flags: .read) { file in
                        let buffer = try await file.readAll()
                        return Data(buffer.readableBytesView)
                    }
                }
            }
        } catch { throw Self.translated(error) }
    }

    public func write(_ data: sending Data, path: String) async throws {
        guard let client = resources.client else { throw PierError.unavailable("SSH is not connected") }
        let payload: ByteBuffer = {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            return buffer
        }()
        do {
            try await client.withSFTP { sftp in
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                    try await file.write(payload)
                }
            }
        } catch { throw Self.translated(error) }
    }

    private func makeClient(_ endpoint: SSHEndpoint) async throws -> SSHClient {
        let provider = keyProvider
        let auth = SecureEnclaveAuthentication(username: endpoint.username, keyID: endpoint.keyID, provider: provider)
        let validator = TrustOnFirstUseValidator(host: endpoint.address, verifier: hostKeyVerifier)
        let settings = SSHClientSettings(
            host: endpoint.address,
            authenticationMethod: { .custom(auth) },
            hostKeyValidator: .custom(validator)
        )
        return try await SSHClient.connect(to: settings)
    }

    private func establishClient(_ endpoint: SSHEndpoint, generation: UInt64) async throws -> SSHClient {
        let policy = retryPolicy
        let establishment = ConnectionEstablishment<SSHClient>(generation: generation) { [self] in
            try await policy.run(safety: .idempotent) { [self] in
                try await makeClient(endpoint)
            }
        }
        self.establishment = establishment
        do {
            return try await establishment.task.value
        } catch {
            throw Self.translated(error)
        }
    }

    private func executeOnce(_ command: String, at endpoint: SSHEndpoint) async throws -> Data {
        let client = try await makeClient(endpoint)
        do {
            let buffer = try await client.executeCommand(command, mergeStreams: true)
            try? await client.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await client.close()
            throw error
        }
    }

    private func setWriter(_ value: TTYStdinWriter, generation: UInt64) {
        guard generation == lifecycle.generation else { return }
        resources.writer = value
    }

    private func yield(_ data: Data, generation: UInt64) {
        guard generation == lifecycle.generation else { return }
        resources.inboundBytes.yield(data)
    }

    private func recordStandardError(_ data: Data, generation: UInt64) {
        guard generation == lifecycle.generation else { return }
        let remainingCapacity = max(0, 4096 - standardError.count)
        standardError.append(data.prefix(remainingCapacity))
    }

    private func finish(_ error: Error?, generation: UInt64) {
        guard generation == lifecycle.generation else { return }
        let resolvedError = error.map(processError)
        resources.inboundBytes.finish(throwing: resolvedError)
        resources.writer = nil
    }

    private func processError(_ error: Error) -> PierError {
        let translatedError = Self.translated(error)
        let details = String(data: standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !details.isEmpty else { return translatedError }
        return .transport("\(translatedError.localizedDescription)\n\(details)")
    }
}

extension CitadelTransport {
    @available(macOS 15, *)
    private func makeStreamTask(
        client: SSHClient,
        command: String,
        ready: AsyncThrowingStream<Void, Error>.Continuation,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self, client] in
            do {
                try await client.withPTY(Self.terminalRequest()) { inbound, outbound in
                    await self?.setWriter(outbound, generation: generation)
                    var buffer = ByteBufferAllocator().buffer(capacity: command.utf8.count + 6)
                    buffer.writeString("exec \(command)\n")
                    try await outbound.write(buffer)
                    ready.yield()
                    ready.finish()
                    for try await event in inbound {
                        switch event {
                        case let .stdout(buffer):
                            await self?.yield(Data(buffer.readableBytesView), generation: generation)
                        case let .stderr(buffer):
                            await self?.recordStandardError(Data(buffer.readableBytesView), generation: generation)
                        }
                    }
                }
                await self?.finish(nil, generation: generation)
            } catch {
                ready.finish(throwing: error)
                await self?.finish(error, generation: generation)
            }
        }
    }

    static func translated(_ error: Error) -> PierError {
        if let error = error as? PierError { return error }
        if let lifecycleError = error as? TransportLifecycleError {
            switch lifecycleError {
            case .connectionInProgress:
                return .unavailable("An SSH connection is already in progress")
            case .superseded:
                return .transport("The SSH connection attempt was superseded")
            }
        }
        if error is CancellationError {
            return .transport("SSH operation was cancelled")
        }
        if let channelError = error as? ChannelError {
            if case .connectTimeout = channelError {
                return .transport("SSHサーバーへの接続がタイムアウトしました。ホスト名とネットワークを確認してください。")
            }
            if case .inputClosed = channelError {
                return .transport("SSH connection input was closed by the remote host")
            }
            if case .eof = channelError {
                return .transport("SSH connection reached end-of-file")
            }
        }
        return .transport(error.localizedDescription)
    }

    static func isTransient(_ error: any Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        if let error = error as? PierError {
            switch error {
            case .authentication, .invalidResponse, .persistence, .unavailable:
                return false
            case .transport:
                return false
            }
        }
        guard let channelError = error as? ChannelError else { return false }
        switch channelError {
        case .connectTimeout, .connectPending:
            return true
        case .operationUnsupported, .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof,
             .writeMessageTooLarge, .writeHostUnreachable, .unknownLocalAddress, .badMulticastGroupAddressFamily,
             .badInterfaceAddressFamily, .illegalMulticastAddress, .multicastNotSupported,
             .inappropriateOperationForState, .unremovableHandler:
            return false
        }
    }

    private static func terminalRequest() -> SSHChannelRequestEvent.PseudoTerminalRequest {
        SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 0, .ECHONL: 0])
        )
    }
}

private final class TrustOnFirstUseValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let verifier: CitadelTransport.HostKeyVerifier
    init(host: String, verifier: @escaping CitadelTransport.HostKeyVerifier) {
        self.host = host; self.verifier = verifier
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        hostKey.write(to: &buffer)
        let data = Data(buffer.readableBytesView)
        validationCompletePromise.completeWithTask {
            guard try await self.verifier(self.host, data) else {
                throw PierError.authentication("SSH host key changed for \(self.host)")
            }
        }
    }
}

private final class SecureEnclaveAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let keyID: KeyID
    private let provider: CitadelTransport.SigningCapabilityProvider
    private var attempted = false
    init(username: String, keyID: KeyID, provider: @escaping CitadelTransport.SigningCapabilityProvider) {
        self.username = username; self.keyID = keyID; self.provider = provider
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey)
        else {
            nextChallengePromise.fail(PierError.authentication("SSHサーバーが公開鍵認証を受け付けていません。"))
            return
        }
        guard !attempted else {
            nextChallengePromise.fail(
                PierError.authentication("公開鍵認証に失敗しました。ユーザー名と登録済みの公開鍵を確認してください。")
            )
            return
        }
        attempted = true
        nextChallengePromise.completeWithTask {
            let material = try await self.provider(self.keyID)
            let privateKey = try ExternalSigningKey.make(capability: material)
            return NIOSSHUserAuthenticationOffer(
                username: self.username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        }
    }
}
