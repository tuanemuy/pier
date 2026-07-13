import Foundation

public struct TUIStateDetector: Sendable {
    public private(set) var isActive = false
    private var tail = Data()
    public init(isActive: Bool = false) {
        self.isActive = isActive
    }

    public mutating func consume(_ data: Data) -> Bool {
        var combined = tail
        combined.append(data)
        let enterSequences = ["\u{1B}[?1049h", "\u{1B}[?1047h", "\u{1B}[?47h"].map { Data($0.utf8) }
        let exitSequences = ["\u{1B}[?1049l", "\u{1B}[?1047l", "\u{1B}[?47l"].map { Data($0.utf8) }
        var transitions: [(Data.Index, Bool)] = []
        for sequence in enterSequences {
            transitions.append(contentsOf: Self.matches(sequence, in: combined).map { ($0, true) })
        }
        for sequence in exitSequences {
            transitions.append(contentsOf: Self.matches(sequence, in: combined).map { ($0, false) })
        }
        for transition in transitions.sorted(by: { $0.0 < $1.0 }) {
            isActive = transition.1
        }
        tail = Data(combined.suffix(12))
        return isActive
    }

    private static func matches(_ sequence: Data, in data: Data) -> [Data.Index] {
        var result: [Data.Index] = []
        var start = data.startIndex
        while start < data.endIndex {
            guard let range = data.range(of: sequence, in: start ..< data.endIndex) else { break }
            result.append(range.lowerBound)
            start = data.index(after: range.lowerBound)
        }
        return result
    }
}

public enum TUIClassifier {
    private static let commands: Set<String> = [
        "vi", "vim", "nvim", "nano", "emacs", "htop", "top", "btop", "less", "more", "man", "fzf",
        "lazygit", "claude"
    ]

    public static func isTUI(_ pane: Pane, detectedAlternateScreen: Bool) -> Bool {
        pane.isAlternateScreen || detectedAlternateScreen || commands.contains(pane.currentCommand)
    }
}
