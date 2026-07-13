import Foundation
import PierSupport

enum DriverOperationSafety {
    case idempotent
    case ambiguousWrite
}

struct DriverRetryPolicy {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias Classifier = @Sendable (any Error) -> Bool

    let maximumAttempts: Int
    let delays: [Duration]
    let sleep: Sleeper
    let isTransient: Classifier

    init(
        maximumAttempts: Int = 3,
        delays: [Duration] = [.milliseconds(50), .milliseconds(100)],
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        isTransient: @escaping Classifier
    ) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
        self.delays = delays
        self.sleep = sleep
        self.isTransient = isTransient
    }

    func run<Value: Sendable>(
        safety: DriverOperationSafety,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard safety == .idempotent,
                      !(error is CancellationError),
                      isTransient(error),
                      attempt < maximumAttempts
                else {
                    throw error
                }
                let delayIndex = min(attempt - 1, max(0, delays.count - 1))
                if !delays.isEmpty {
                    try await sleep(delays[delayIndex])
                }
                attempt += 1
            }
        }
    }
}
