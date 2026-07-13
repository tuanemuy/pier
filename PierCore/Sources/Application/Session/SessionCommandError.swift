import Foundation

public enum SessionCommandError: Error, Equatable, LocalizedError, Sendable {
    case disconnected
    case staleGeneration
    case createdWindowCountMismatch(Int)

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "No connected tmux session"
        case .staleGeneration:
            "The tmux session changed while the command was running"
        case let .createdWindowCountMismatch(count):
            "Expected one newly created tmux window, found \(count)"
        }
    }
}
