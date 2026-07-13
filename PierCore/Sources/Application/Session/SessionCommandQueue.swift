@MainActor
final class SessionCommandQueue {
    let generation: UInt64
    var tail: Task<Void, Never>?
    private var nextToken: UInt64 = 0
    private var cancellations: [UInt64: () -> Void] = [:]

    init(generation: UInt64) {
        self.generation = generation
    }

    func invalidate() {
        let values = cancellations.values
        cancellations.removeAll()
        for cancel in values {
            cancel()
        }
        tail?.cancel()
        tail = nil
    }

    func own(_ task: Task<some Any, Error>) -> UInt64 {
        let token = nextToken
        nextToken &+= 1
        cancellations[token] = { task.cancel() }
        return token
    }

    func release(_ token: UInt64) {
        cancellations.removeValue(forKey: token)
    }
}
