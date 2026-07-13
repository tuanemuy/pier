public enum SessionTreeRecordFormat {
    public static let delimiter = "\u{1F}"

    public static let windows = [
        "#{session_id}",
        "#{session_name}",
        "#{window_id}",
        "#{window_index}",
        "#{window_name}",
        "#{window_active}"
    ].joined(separator: delimiter)

    public static let panes = [
        "#{session_id}",
        "#{window_id}",
        "#{pane_id}",
        "#{pane_left}",
        "#{pane_top}",
        "#{pane_title}",
        "#{pane_current_command}",
        "#{pane_current_path}",
        "#{pane_width}",
        "#{pane_height}",
        "#{alternate_on}",
        "#{pane_active}"
    ].joined(separator: delimiter)
}

public enum SessionTreeRecordKind: String, Equatable, Sendable {
    case window
    case pane
}

public enum SessionTreeParseError: Error, Equatable, Sendable {
    case malformedRecord(kind: SessionTreeRecordKind, lineNumber: Int, line: String)
    case duplicateWindow(WindowID)
    case duplicatePane(PaneID)
    case inconsistentSessionName(SessionID)
    case paneWithoutWindow(paneID: PaneID, windowID: WindowID)
    case paneSessionMismatch(paneID: PaneID, expected: SessionID, actual: SessionID)
    case multipleActiveWindows(SessionID)
    case multipleActivePanes(WindowID)
}

public enum SessionTreeResponseParser {
    public static func parse(
        windowLines: [String],
        paneLines: [String]
    ) throws(SessionTreeParseError) -> [TmuxSession] {
        let windows = try parseWindows(windowLines)
        let panes = try parsePanes(paneLines)
        let windowsByID = try indexWindows(windows)
        let panesByWindowID = try indexPanes(panes, windowsByID: windowsByID)
        return try buildSessions(windows: windows, panesByWindowID: panesByWindowID)
            .sorted(by: sessionOrder)
    }

    private static func buildSessions(
        windows: [WindowRecord],
        panesByWindowID: [WindowID: [PaneRecord]]
    ) throws(SessionTreeParseError) -> [TmuxSession] {
        let windowsBySessionID = Dictionary(grouping: windows, by: \.sessionID)
        var sessions: [TmuxSession] = []
        sessions.reserveCapacity(windowsBySessionID.count)
        for (sessionID, records) in windowsBySessionID {
            guard let first = records.first else { continue }
            guard records.allSatisfy({ $0.sessionName == first.sessionName }) else {
                throw SessionTreeParseError.inconsistentSessionName(sessionID)
            }
            guard records.lazy.filter(\.active).count <= 1 else {
                throw .multipleActiveWindows(sessionID)
            }

            var sessionWindows: [TmuxWindow] = []
            for record in records.sorted(by: windowOrder) {
                let paneRecords = panesByWindowID[record.id, default: []]
                guard paneRecords.lazy.filter(\.active).count <= 1 else {
                    throw .multipleActivePanes(record.id)
                }
                sessionWindows.append(TmuxWindow(
                    id: record.id,
                    index: record.index,
                    name: record.name,
                    panes: paneRecords.map(\.pane),
                    activePaneID: paneRecords.first(where: \.active)?.pane.id
                ))
            }
            sessions.append(TmuxSession(
                id: sessionID,
                name: first.sessionName,
                windows: sessionWindows,
                activeWindowID: records.first(where: \.active)?.id
            ))
        }
        return sessions
    }

    private struct WindowRecord {
        let sessionID: SessionID
        let sessionName: String
        let id: WindowID
        let index: Int
        let name: String
        let active: Bool
    }

    private struct PaneRecord {
        let sessionID: SessionID
        let windowID: WindowID
        let pane: Pane
        let active: Bool
    }

    private static func parseWindows(_ lines: [String]) throws(SessionTreeParseError) -> [WindowRecord] {
        var records: [WindowRecord] = []
        records.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            try records.append(parseWindow(line, lineNumber: offset + 1))
        }
        return records
    }

    private static func parsePanes(_ lines: [String]) throws(SessionTreeParseError) -> [PaneRecord] {
        var records: [PaneRecord] = []
        records.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            try records.append(parsePane(line, lineNumber: offset + 1))
        }
        return records
    }

    private static func indexWindows(
        _ windows: [WindowRecord]
    ) throws(SessionTreeParseError) -> [WindowID: WindowRecord] {
        var windowsByID: [WindowID: WindowRecord] = [:]
        for window in windows {
            guard windowsByID.updateValue(window, forKey: window.id) == nil else {
                throw .duplicateWindow(window.id)
            }
        }
        return windowsByID
    }

    private static func indexPanes(
        _ panes: [PaneRecord],
        windowsByID: [WindowID: WindowRecord]
    ) throws(SessionTreeParseError) -> [WindowID: [PaneRecord]] {
        var paneIDs = Set<PaneID>()
        var panesByWindowID: [WindowID: [PaneRecord]] = [:]
        for pane in panes {
            guard paneIDs.insert(pane.pane.id).inserted else {
                throw .duplicatePane(pane.pane.id)
            }
            guard let window = windowsByID[pane.windowID] else {
                throw .paneWithoutWindow(paneID: pane.pane.id, windowID: pane.windowID)
            }
            guard window.sessionID == pane.sessionID else {
                throw .paneSessionMismatch(
                    paneID: pane.pane.id,
                    expected: window.sessionID,
                    actual: pane.sessionID
                )
            }
            panesByWindowID[pane.windowID, default: []].append(pane)
        }
        return panesByWindowID
    }

    private static func parseWindow(
        _ line: String,
        lineNumber: Int
    ) throws(SessionTreeParseError) -> WindowRecord {
        let parts = fields(in: line)
        guard parts.count == 6,
              let sessionID = identifier(SessionID.self, from: parts[0]),
              let windowID = identifier(WindowID.self, from: parts[2]),
              let index = Int(parts[3]), index >= 0,
              let active = boolean(parts[5])
        else {
            throw .malformedRecord(kind: .window, lineNumber: lineNumber, line: line)
        }
        return WindowRecord(
            sessionID: sessionID,
            sessionName: parts[1],
            id: windowID,
            index: index,
            name: parts[4],
            active: active
        )
    }

    private static func parsePane(
        _ line: String,
        lineNumber: Int
    ) throws(SessionTreeParseError) -> PaneRecord {
        let parts = fields(in: line)
        guard parts.count == 10 || parts.count == 12,
              let sessionID = identifier(SessionID.self, from: parts[0]),
              let windowID = identifier(WindowID.self, from: parts[1]),
              let paneID = identifier(PaneID.self, from: parts[2]),
              let x = Int(parts[3]), x >= 0,
              let y = Int(parts[4]), y >= 0,
              let width = positiveInteger(parts.count == 12 ? parts[8] : "1"),
              let height = positiveInteger(parts.count == 12 ? parts[9] : "1"),
              let alternateScreen = boolean(parts[parts.count - 2]),
              let active = boolean(parts[parts.count - 1])
        else {
            throw .malformedRecord(kind: .pane, lineNumber: lineNumber, line: line)
        }
        return PaneRecord(
            sessionID: sessionID,
            windowID: windowID,
            pane: Pane(
                id: paneID,
                position: GridPosition(x: x, y: y),
                title: parts[5],
                currentCommand: parts[6],
                currentPath: parts[7],
                isAlternateScreen: alternateScreen,
                width: width,
                height: height
            ),
            active: active
        )
    }

    private static func fields(in line: String) -> [String] {
        line.components(separatedBy: SessionTreeRecordFormat.delimiter)
    }

    private static func identifier<ID: PierIdentifier>(_: ID.Type, from rawValue: String) -> ID? {
        switch ID.parse(rawValue) {
        case let .success(identifier): identifier
        case .failure: nil
        }
    }

    private static func boolean(_ value: String) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }

    private static func positiveInteger(_ value: String) -> Int? {
        guard let result = Int(value), result > 0 else { return nil }
        return result
    }

    private static func windowOrder(_ lhs: WindowRecord, _ rhs: WindowRecord) -> Bool {
        if lhs.index != rhs.index { return lhs.index < rhs.index }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func sessionOrder(_ lhs: TmuxSession, _ rhs: TmuxSession) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
