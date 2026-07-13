import Foundation

public enum TmuxMessage: Equatable, Sendable {
    case begin(timestamp: UInt64, commandNumber: UInt64, flags: Int)
    case end(timestamp: UInt64, commandNumber: UInt64, flags: Int)
    case commandError(timestamp: UInt64, commandNumber: UInt64, flags: Int)
    case output(paneID: PaneID, data: Data)
    case windowAdded(WindowID)
    case windowClosed(WindowID)
    case windowRenamed(windowID: WindowID, name: String)
    case layoutChanged(windowID: WindowID, layout: String)
    case sessionChanged(sessionID: SessionID, name: String)
    case sessionsChanged
    case exit(reason: String?)
    case connectionClosed(reason: String)
    case responseLine(String)
    case unknown(String)
}

public enum TmuxParseError: Error, Equatable, Sendable {
    case malformed(String)
    case invalidOctalEscape(String)
    case invalidUTF8
}
