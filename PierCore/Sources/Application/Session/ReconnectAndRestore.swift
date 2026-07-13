import Foundation
import PierSupport

public enum ReconnectAndRestoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidMaximumAttempts(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidMaximumAttempts(value): "maximumAttempts must be positive: \(value)"
        }
    }
}

public struct ReconnectAndRestore: Sendable {
    public static let maximumSupportedAttempts = 8
    private let clock: any Clock
    private let attachTimeout: Duration

    public init(clock: any Clock, attachTimeout: Duration = .seconds(10)) {
        self.clock = clock
        self.attachTimeout = attachTimeout
    }

    @discardableResult
    public func callAsFunction(
        gateway: TmuxGateway,
        endpoint: SSHEndpoint,
        sessionName: String,
        maximumAttempts: Int = 5,
        lease: SessionOperationLease = SessionOperationLease(),
        onAttempt: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws -> AttachSessionOutcome {
        guard (1 ... Self.maximumSupportedAttempts).contains(maximumAttempts) else {
            throw ReconnectAndRestoreError.invalidMaximumAttempts(maximumAttempts)
        }
        for attempt in 1 ... maximumAttempts {
            try await lease.check()
            await onAttempt(attempt)
            try await lease.check()
            do {
                let outcome = try await AttachSession(clock: clock, timeout: attachTimeout)(
                    gateway: gateway,
                    endpoint: endpoint,
                    sessionName: sessionName,
                    lease: lease
                )
                try await lease.check()
                return outcome
            } catch let error as PierError where error.isRetryableTransportFailure {
                guard attempt < maximumAttempts else { throw error }
                try await clock.sleep(for: Self.backoff(for: attempt))
                try await lease.check()
            }
        }
        throw ReconnectAndRestoreError.invalidMaximumAttempts(maximumAttempts)
    }

    public static func backoff(for failedAttempt: Int) -> Duration {
        let exponent = min(max(failedAttempt - 1, 0), 4)
        return .milliseconds(Int64(min(250 * (1 << exponent), 4000)))
    }
}

private extension PierError {
    var isRetryableTransportFailure: Bool {
        if case .transport = self { return true }
        return false
    }
}
