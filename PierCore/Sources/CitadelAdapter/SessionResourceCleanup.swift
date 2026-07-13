struct SessionResourceCleanup {
    let cancelProducer: @Sendable () -> Void
    let closeClient: @Sendable () async -> Void
    let waitForProducer: @Sendable () async -> Void

    func run() async {
        cancelProducer()
        await closeClient()
        await waitForProducer()
    }
}
