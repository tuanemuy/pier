import Foundation

public enum PierError: Error, Equatable, LocalizedError, Sendable {
    case transport(String)
    case authentication(String)
    case unavailable(String)
    case persistence(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .transport(message),
             let .authentication(message),
             let .unavailable(message),
             let .persistence(message),
             let .invalidResponse(message):
            message
        }
    }
}
