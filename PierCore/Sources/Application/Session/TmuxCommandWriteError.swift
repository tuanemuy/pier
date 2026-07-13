import Foundation
import PierSupport

public enum TmuxCommandWriteError: Error, Equatable, LocalizedError, Sendable {
    case failed(PierError)

    public var errorDescription: String? {
        switch self {
        case let .failed(error): error.localizedDescription
        }
    }
}
