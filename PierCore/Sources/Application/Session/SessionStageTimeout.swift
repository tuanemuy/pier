struct SessionStageTimeout {
    private enum Race<Value: Sendable> {
        case value(Value)
        case timeout
    }

    private let clock: any Clock
    private let duration: Duration

    init(clock: any Clock, duration: Duration) {
        self.clock = clock
        self.duration = duration
    }

    func run<Value: Sendable>(
        stage: AttachSessionStage,
        lease: SessionOperationLease,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await lease.check()
        return try await withThrowingTaskGroup(of: Race<Value>.self) { group in
            group.addTask {
                let value = try await operation()
                try await lease.check()
                return .value(value)
            }
            group.addTask {
                try await clock.sleep(for: duration)
                return .timeout
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            switch first {
            case let .value(value):
                return value
            case .timeout:
                try await lease.check()
                await onTimeout()
                throw AttachSessionError.timedOut(stage: stage)
            }
        }
    }
}
