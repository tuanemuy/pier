import Foundation
import Observation
import PierDomain

public struct SessionSelection: Equatable, Sendable {
    public let sessionID: SessionID
    public let windowID: WindowID
    public let paneID: PaneID

    public init(sessionID: SessionID, windowID: WindowID, paneID: PaneID) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.paneID = paneID
    }
}

@MainActor @Observable
public final class SessionModel {
    public enum Connection: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(SessionFailure)
    }

    public private(set) var connection: Connection = .disconnected
    public private(set) var sessions: [TmuxSession] = []
    public private(set) var selection: SessionSelection?
    public private(set) var blocks: [PaneID: [CommandBlock]] = [:]
    public private(set) var tuiPaneIDs: Set<PaneID> = []
    @ObservationIgnored private var blockParsers: [PaneID: OSC133Parser] = [:]
    @ObservationIgnored private var blockReducers: [PaneID: OSC133Reducer] = [:]
    @ObservationIgnored private var tuiDetectors: [PaneID: TUIStateDetector] = [:]

    public init() {}

    public var selectedSessionID: SessionID? {
        selection?.sessionID
    }

    public var selectedWindowID: WindowID? {
        selection?.windowID
    }

    public var selectedPaneID: PaneID? {
        selection?.paneID
    }

    public var selectedSession: TmuxSession? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection.sessionID }
    }

    public var selectedWindow: TmuxWindow? {
        guard let selection else { return nil }
        return selectedSession?.windows.first { $0.id == selection.windowID }
    }

    public var selectedPane: Pane? {
        guard let selection else { return nil }
        return selectedWindow?.panes.first { $0.id == selection.paneID }
    }

    func setConnection(_ value: Connection) {
        connection = value
    }

    public func replaceSessions(_ value: [TmuxSession], preferredSessionName: String? = nil) {
        sessions = value
        let existingPaneIDs = Set(value.flatMap(\.windows).flatMap(\.panes).map(\.id))
        tuiPaneIDs.formIntersection(existingPaneIDs)
        blocks = blocks.filter { existingPaneIDs.contains($0.key) }
        blockParsers = blockParsers.filter { existingPaneIDs.contains($0.key) }
        blockReducers = blockReducers.filter { existingPaneIDs.contains($0.key) }
        tuiDetectors = tuiDetectors.filter { existingPaneIDs.contains($0.key) }
        if let selection, Self.contains(selection, in: value) { return }
        let preferred = preferredSessionName.flatMap { name in value.first { $0.name == name } }
        selection = Self.defaultSelection(in: preferred ?? value.first)
    }

    @discardableResult
    public func select(sessionID: SessionID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let next = Self.defaultSelection(in: session)
        else { return false }
        selection = next
        return true
    }

    @discardableResult
    public func select(windowID: WindowID) -> Bool {
        guard let session = sessions.first(where: { $0.windows.contains(where: { $0.id == windowID }) }),
              let window = session.windows.first(where: { $0.id == windowID }),
              let paneID = window.activePaneID ?? window.panes.first?.id
        else { return false }
        selection = SessionSelection(sessionID: session.id, windowID: window.id, paneID: paneID)
        return true
    }

    @discardableResult
    public func select(paneID: PaneID) -> Bool {
        for session in sessions {
            if let window = session.windows.first(where: { $0.panes.contains(where: { $0.id == paneID }) }) {
                selection = SessionSelection(sessionID: session.id, windowID: window.id, paneID: paneID)
                return true
            }
        }
        return false
    }

    public func submit(command: String, paneID: PaneID, blockID: UUID, now: Date) {
        var reducer = blockReducers[paneID] ?? OSC133Reducer(blocks: blocks[paneID, default: []])
        reducer.reduce(.commandStart(command), now: now, blockID: blockID)
        blockReducers[paneID] = reducer
        blocks[paneID] = reducer.blocks
    }

    public func rollbackSubmission(paneID: PaneID, blockID: UUID) {
        guard var reducer = blockReducers[paneID] else { return }
        reducer.rollbackSubmission(blockID: blockID)
        blockReducers[paneID] = reducer
        blocks[paneID] = reducer.blocks
    }

    public func replaceScrollbackSnapshot(
        _ data: Data,
        journal: [CommandBlock] = [],
        paneID: PaneID,
        blockID: UUID,
        now: Date
    ) {
        let output = TerminalText.plain(data).trimmingCharacters(in: .whitespacesAndNewlines)
        let reconciled = CommandHistoryReconciler.reconcile(capture: output, journal: journal)
        var restored: [CommandBlock] = []
        if !reconciled.restoredPrefix.isEmpty {
            restored.append(CommandBlock(
                id: blockID,
                command: "",
                output: reconciled.restoredPrefix,
                startedAt: now,
                duration: nil,
                status: .restored
            ))
        }
        restored.append(contentsOf: reconciled.blocks)
        let reducer = OSC133Reducer(blocks: restored)
        blockReducers[paneID] = reducer
        blockParsers[paneID] = OSC133Parser()
        blocks[paneID] = reducer.blocks
    }

    @discardableResult
    public func consumeShellOutput(_ data: Data, paneID: PaneID, now: Date, blockID: UUID) -> Bool {
        var detector = tuiDetectors[paneID] ?? TUIStateDetector(isActive: tuiPaneIDs.contains(paneID))
        if detector.consume(data) { tuiPaneIDs.insert(paneID) } else { tuiPaneIDs.remove(paneID) }
        tuiDetectors[paneID] = detector

        var parser = blockParsers[paneID] ?? OSC133Parser()
        let events = parser.consume(data)
        blockParsers[paneID] = parser
        var reducer = blockReducers[paneID] ?? OSC133Reducer(blocks: blocks[paneID, default: []])
        var commandFinished = false
        for event in events {
            switch event {
            case .promptStarted:
                reducer.reduce(.prompt, now: now, blockID: blockID)
            case .commandStarted:
                break
            case let .output(text):
                reducer.reduce(.output(text), now: now, blockID: blockID)
            case let .commandFinished(exitCode):
                reducer.reduce(.commandFinished(exitCode), now: now, blockID: blockID)
                commandFinished = true
            }
        }
        blockReducers[paneID] = reducer
        blocks[paneID] = reducer.blocks
        return commandFinished
    }

    public func isTUI(_ pane: Pane) -> Bool {
        TUIClassifier.isTUI(pane, detectedAlternateScreen: tuiPaneIDs.contains(pane.id))
    }

    private static func contains(_ selection: SessionSelection, in sessions: [TmuxSession]) -> Bool {
        sessions.contains { session in
            session.id == selection.sessionID && session.windows.contains { window in
                window.id == selection.windowID && window.panes.contains { $0.id == selection.paneID }
            }
        }
    }

    private static func defaultSelection(in session: TmuxSession?) -> SessionSelection? {
        guard let session,
              let windowID = session.activeWindowID ?? session.windows.first?.id,
              let window = session.windows.first(where: { $0.id == windowID }),
              let paneID = window.activePaneID ?? window.panes.first?.id
        else { return nil }
        return SessionSelection(sessionID: session.id, windowID: window.id, paneID: paneID)
    }
}
