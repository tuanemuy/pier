import Foundation

enum TransportLifecycleError: Error, Equatable, LocalizedError {
    case connectionInProgress
    case superseded

    var errorDescription: String? {
        switch self {
        case .connectionInProgress: "An SSH connection is already in progress"
        case .superseded: "The SSH connection attempt was superseded"
        }
    }
}

struct TransportLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var connectionInProgress = false

    mutating func beginConnection() throws -> UInt64 {
        guard !connectionInProgress else { throw TransportLifecycleError.connectionInProgress }
        connectionInProgress = true
        generation &+= 1
        return generation
    }

    mutating func finishConnection(generation candidate: UInt64) {
        guard candidate == generation else { return }
        connectionInProgress = false
    }

    mutating func finishInvalidatedConnection(generation candidate: UInt64) {
        guard candidate == generation else { return }
        connectionInProgress = false
    }

    @discardableResult
    mutating func invalidateCurrentGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidateConnection(ownedBy candidate: UInt64) -> UInt64? {
        guard candidate == generation else { return nil }
        return invalidateCurrentGeneration()
    }

    func validate(_ candidate: UInt64) throws {
        guard candidate == generation else { throw TransportLifecycleError.superseded }
    }
}
