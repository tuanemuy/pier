import Foundation
import PierDomain
import PierSupport

public enum SessionFailure: Equatable, Sendable {
    case attach(AttachSessionError)
    case sessionTree(SessionTreeParseError)
    case startup(TmuxStartupError)
    case commandProtocol(TmuxCommandProtocolError)
    case commandWrite(TmuxCommandWriteError)
    case connection(TmuxConnectionError)
    case command(SessionCommandError)
    case transport(PierError)
    case tmuxParse(TmuxParseError)
    case cancelled
    case unclassified(type: String)

    public static func classify(_ error: Error) -> SessionFailure {
        switch error {
        case let value as AttachSessionError: .attach(value)
        case let value as SessionTreeParseError: .sessionTree(value)
        case let value as TmuxStartupError: .startup(value)
        case let value as TmuxCommandProtocolError: .commandProtocol(value)
        case let value as TmuxCommandWriteError: .commandWrite(value)
        case let value as TmuxConnectionError: .connection(value)
        case let value as SessionCommandError: .command(value)
        case let value as PierError: .transport(value)
        case let value as TmuxParseError: .tmuxParse(value)
        case is CancellationError: .cancelled
        default: .unclassified(type: String(reflecting: type(of: error)))
        }
    }
}
