public enum TmuxKey: Equatable, Sendable {
    public enum Arrow: Equatable, Sendable {
        case upward
        case downward
        case leftward
        case rightward
    }

    public enum Control: Equatable, Sendable {
        case letterB
        case letterC
        case escape
        case tab
        case upward
        case downward
        case leftward
        case rightward
    }

    case escape
    case tab
    case enter
    case arrow(Arrow)
    case control(Control)

    public static func parse(_ rawValue: String) -> Result<Self, TmuxKeyError> {
        switch rawValue {
        case "Escape": .success(.escape)
        case "Tab": .success(.tab)
        case "Enter": .success(.enter)
        case "Up": .success(.arrow(.upward))
        case "Down": .success(.arrow(.downward))
        case "Left": .success(.arrow(.leftward))
        case "Right": .success(.arrow(.rightward))
        case "C-b": .success(.control(.letterB))
        case "C-c": .success(.control(.letterC))
        case "C-Escape": .success(.control(.escape))
        case "C-Tab": .success(.control(.tab))
        case "C-Up": .success(.control(.upward))
        case "C-Down": .success(.control(.downward))
        case "C-Left": .success(.control(.leftward))
        case "C-Right": .success(.control(.rightward))
        default: .failure(.invalidToken)
        }
    }

    public var commandToken: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .enter: "Enter"
        case let .arrow(arrow):
            switch arrow {
            case .upward: "Up"
            case .downward: "Down"
            case .leftward: "Left"
            case .rightward: "Right"
            }
        case let .control(control):
            switch control {
            case .letterB: "C-b"
            case .letterC: "C-c"
            case .escape: "C-Escape"
            case .tab: "C-Tab"
            case .upward: "C-Up"
            case .downward: "C-Down"
            case .leftward: "C-Left"
            case .rightward: "C-Right"
            }
        }
    }
}

public enum TmuxKeyError: Error, Equatable, Sendable {
    case invalidToken
}
