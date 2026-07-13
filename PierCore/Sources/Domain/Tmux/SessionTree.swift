public struct Pane: Identifiable, Equatable, Sendable {
    public let id: PaneID
    public let position: GridPosition
    public let title: String
    public let currentCommand: String
    public let currentPath: String
    public let isAlternateScreen: Bool
    public let width: Int
    public let height: Int
    public init(
        id: PaneID,
        position: GridPosition,
        title: String = "",
        currentCommand: String = "shell",
        currentPath: String = "~",
        isAlternateScreen: Bool = false,
        width: Int = 1,
        height: Int = 1
    ) {
        self.id = id; self.position = position; self.title = title; self.currentCommand = currentCommand
        self.currentPath = currentPath; self.isAlternateScreen = isAlternateScreen
        self.width = width; self.height = height
    }
}

public struct TmuxWindow: Identifiable, Equatable, Sendable {
    public let id: WindowID
    public let index: Int
    public let name: String
    public let panes: [Pane]
    public let activePaneID: PaneID?
    public init(id: WindowID, index: Int, name: String, panes: [Pane], activePaneID: PaneID?) {
        self.id = id; self.index = index; self.name = name; self.panes = panes; self.activePaneID = activePaneID
    }
}

public struct TmuxSession: Identifiable, Equatable, Sendable {
    public let id: SessionID
    public let name: String
    public let windows: [TmuxWindow]
    public let activeWindowID: WindowID?
    public init(id: SessionID, name: String, windows: [TmuxWindow], activeWindowID: WindowID?) {
        self.id = id; self.name = name; self.windows = windows; self.activeWindowID = activeWindowID
    }
}

public struct PaneGrid: Equatable, Sendable {
    public let panes: [Pane]
    public init(panes: [Pane]) {
        self.panes = panes
    }

    public func pane(from paneID: PaneID, toward direction: Direction) -> Pane? {
        guard let current = panes.first(where: { $0.id == paneID }) else { return nil }
        let candidates = panes.filter { candidate in
            guard overlapsPerpendicularAxis(candidate, current, direction) else { return false }
            return switch direction {
            case .upward: candidate.position.y < current.position.y
            case .downward: candidate.position.y > current.position.y
            case .leftward: candidate.position.x < current.position.x
            case .rightward: candidate.position.x > current.position.x
            }
        }
        return candidates.min { lhs, rhs in
            distance(lhs.position, current.position, direction) < distance(rhs.position, current.position, direction)
        }
    }

    private func overlapsPerpendicularAxis(_ candidate: Pane, _ current: Pane, _ direction: Direction) -> Bool {
        switch direction {
        case .upward, .downward:
            rangesOverlap(
                candidate.position.x ..< candidate.position.x + candidate.width,
                current.position.x ..< current.position.x + current.width
            )
        case .leftward, .rightward:
            rangesOverlap(
                candidate.position.y ..< candidate.position.y + candidate.height,
                current.position.y ..< current.position.y + current.height
            )
        }
    }

    private func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    public func splitCommand(paneID: PaneID, toward direction: Direction) -> String {
        let flags = switch direction {
        case .leftward: "-h -b"
        case .rightward: "-h"
        case .upward: "-v -b"
        case .downward: "-v"
        }
        return "split-window \(flags) -t \(paneID.rawValue)"
    }

    private func distance(_ candidate: GridPosition, _ current: GridPosition, _ direction: Direction) -> Int {
        let primary: Int; let cross: Int
        switch direction {
        case .upward, .downward:
            primary = abs(candidate.y - current.y); cross = abs(candidate.x - current.x)
        case .leftward, .rightward:
            primary = abs(candidate.x - current.x); cross = abs(candidate.y - current.y)
        }
        return primary * 1000 + cross
    }
}
