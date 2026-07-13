import Foundation

public protocol PierIdentifier: Hashable, Sendable {
    var rawValue: String { get }
    static func parse(_ rawValue: String) -> Result<Self, IdentifierError>
}

public enum IdentifierError: Error, Equatable, Sendable { case empty, invalid }

public struct HostID: PierIdentifier {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func parse(_ rawValue: String) -> Result<Self, IdentifierError> {
        parseOpaque(rawValue, make: Self.init(rawValue:))
    }
}

public struct KeyID: PierIdentifier {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func parse(_ rawValue: String) -> Result<Self, IdentifierError> {
        parseOpaque(rawValue, make: Self.init(rawValue:))
    }
}

public struct SessionID: PierIdentifier {
    public let rawValue: String
    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func parse(_ rawValue: String) -> Result<Self, IdentifierError> {
        parseTmux(rawValue, prefix: TmuxIdentifierPrefix.session, make: Self.init(rawValue:))
    }
}

public struct WindowID: PierIdentifier {
    public let rawValue: String
    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func parse(_ rawValue: String) -> Result<Self, IdentifierError> {
        parseTmux(rawValue, prefix: TmuxIdentifierPrefix.window, make: Self.init(rawValue:))
    }
}

public struct PaneID: PierIdentifier {
    public let rawValue: String
    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func parse(_ rawValue: String) -> Result<Self, IdentifierError> {
        parseTmux(rawValue, prefix: TmuxIdentifierPrefix.pane, make: Self.init(rawValue:))
    }
}

private func parseOpaque<ID>(_ rawValue: String, make: (String) -> ID) -> Result<ID, IdentifierError> {
    guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(.empty)
    }
    return .success(make(rawValue))
}

private enum TmuxIdentifierPrefix {
    static let session: UInt8 = 0x24
    static let window: UInt8 = 0x40
    static let pane: UInt8 = 0x25
}

private func parseTmux<ID>(
    _ rawValue: String,
    prefix: UInt8,
    make: (String) -> ID
) -> Result<ID, IdentifierError> {
    let bytes = rawValue.utf8
    guard let first = bytes.first else { return .failure(.empty) }
    let suffix = bytes.dropFirst()
    guard first == prefix,
          !suffix.isEmpty,
          suffix.allSatisfy({ (48 ... 57).contains($0) })
    else {
        return .failure(.invalid)
    }
    return .success(make(rawValue))
}

public enum Direction: String, CaseIterable, Sendable {
    case upward = "up"
    case downward = "down"
    case leftward = "left"
    case rightward = "right"
}

public struct GridPosition: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) {
        self.x = x; self.y = y
    }

    public func moved(_ direction: Direction) -> Self {
        switch direction {
        case .upward: Self(x: x, y: y - 1)
        case .downward: Self(x: x, y: y + 1)
        case .leftward: Self(x: x - 1, y: y)
        case .rightward: Self(x: x + 1, y: y)
        }
    }
}
