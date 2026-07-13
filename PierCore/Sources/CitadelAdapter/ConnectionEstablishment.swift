struct ConnectionEstablishment<Value: Sendable> {
    let generation: UInt64
    let task: Task<Value, Error>

    init(
        generation: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        self.generation = generation
        task = Task(operation: operation)
    }

    func cancelAndWait() async {
        task.cancel()
        _ = await task.result
    }
}
