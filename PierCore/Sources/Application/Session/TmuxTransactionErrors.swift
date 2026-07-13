import Foundation

public struct TmuxTransactionMarker: Equatable, Sendable {
    public let timestamp: UInt64
    public let commandNumber: UInt64
    public let flags: Int

    public init(timestamp: UInt64, commandNumber: UInt64, flags: Int) {
        self.timestamp = timestamp
        self.commandNumber = commandNumber
        self.flags = flags
    }
}

public enum TmuxStartupError: Error, Equatable, LocalizedError, Sendable {
    case invalidUTF8
    case malformedLine(String)
    case duplicateBegin(expected: TmuxTransactionMarker, actual: TmuxTransactionMarker)
    case unexpectedEnd(expected: TmuxTransactionMarker?, actual: TmuxTransactionMarker)
    case unexpectedCommandError(expected: TmuxTransactionMarker?, actual: TmuxTransactionMarker)
    case commandFailed([String])

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "tmux startup response contains invalid UTF-8"
        case let .malformedLine(line): "Malformed tmux startup response: \(line)"
        case let .duplicateBegin(expected, actual):
            "Duplicate tmux startup begin: expected \(expected), received \(actual)"
        case let .unexpectedEnd(expected, actual):
            "Unexpected tmux startup end: expected \(String(describing: expected)), received \(actual)"
        case let .unexpectedCommandError(expected, actual):
            "Unexpected tmux startup error: expected \(String(describing: expected)), received \(actual)"
        case let .commandFailed(response):
            response.isEmpty ? "tmux startup command failed" : response.joined(separator: "\n")
        }
    }
}

public enum TmuxCommandProtocolError: Error, Equatable, LocalizedError, Sendable {
    case duplicateBegin(expected: TmuxTransactionMarker, actual: TmuxTransactionMarker)
    case unexpectedEnd(expected: TmuxTransactionMarker?, actual: TmuxTransactionMarker)
    case unexpectedCommandError(expected: TmuxTransactionMarker?, actual: TmuxTransactionMarker)

    public var errorDescription: String? {
        switch self {
        case let .duplicateBegin(expected, actual):
            "Duplicate tmux command begin: expected \(expected), received \(actual)"
        case let .unexpectedEnd(expected, actual):
            "Unexpected tmux command end: expected \(String(describing: expected)), received \(actual)"
        case let .unexpectedCommandError(expected, actual):
            "Unexpected tmux command error: expected \(String(describing: expected)), received \(actual)"
        }
    }
}

public enum TmuxConnectionError: Error, Equatable, LocalizedError, Sendable {
    case connectionInProgress
    case alreadyConnected
    case superseded

    public var errorDescription: String? {
        switch self {
        case .connectionInProgress: "A tmux connection is already in progress"
        case .alreadyConnected: "A tmux connection is already active"
        case .superseded: "The tmux connection attempt was superseded"
        }
    }
}
