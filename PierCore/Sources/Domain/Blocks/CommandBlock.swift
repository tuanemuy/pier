import Foundation

public enum CommandStatus: Equatable, Sendable { case running, restored, finished(exitCode: Int) }

public struct CommandBlock: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let command: String
    public let output: String
    public let startedAt: Date
    public let duration: Duration?
    public let status: CommandStatus
    public init(
        id: UUID,
        command: String,
        output: String,
        startedAt: Date,
        duration: Duration?,
        status: CommandStatus
    ) {
        self.id = id; self.command = command; self.output = output; self.startedAt = startedAt; self
            .duration = duration; self.status = status
    }

    public var outputLines: Int {
        output.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

public struct OSC133Reducer: Sendable {
    public enum Event: Equatable, Sendable { case prompt, commandStart(String), output(String), commandFinished(Int) }
    public private(set) var blocks: [CommandBlock] = []
    public init() {}
    public init(blocks: [CommandBlock]) {
        self.blocks = blocks
    }

    public mutating func restoreSnapshot(output: String, now: Date, blockID: UUID) {
        guard !output.isEmpty else {
            blocks = []
            return
        }
        blocks = [CommandBlock(
            id: blockID,
            command: "",
            output: output,
            startedAt: now,
            duration: nil,
            status: .restored
        )]
    }

    public mutating func reduce(_ event: Event, now: Date, blockID: UUID) {
        switch event {
        case .prompt: break
        case let .commandStart(command): blocks.append(CommandBlock(
                id: blockID,
                command: command,
                output: "",
                startedAt: now,
                duration: nil,
                status: .running
            ))
        case let .output(text):
            guard let block = blocks.last, block.status == .running else { return }
            blocks[blocks.count - 1] = CommandBlock(
                id: block.id,
                command: block.command,
                output: block.output + text,
                startedAt: block.startedAt,
                duration: nil,
                status: .running
            )
        case let .commandFinished(code):
            guard let block = blocks.last, block.status == .running else { return }
            let seconds = max(0, now.timeIntervalSince(block.startedAt))
            blocks[blocks.count - 1] = CommandBlock(
                id: block.id,
                command: block.command,
                output: block.output,
                startedAt: block.startedAt,
                duration: .milliseconds(Int64(seconds * 1000)),
                status: .finished(exitCode: code)
            )
        }
    }

    public mutating func rollbackSubmission(blockID: UUID) {
        guard let block = blocks.last,
              block.id == blockID,
              block.status == .running,
              block.output.isEmpty
        else { return }
        blocks.removeLast()
    }
}

public struct ReconciledCommandHistory: Equatable, Sendable {
    public let restoredPrefix: String
    public let blocks: [CommandBlock]

    public init(restoredPrefix: String, blocks: [CommandBlock]) {
        self.restoredPrefix = restoredPrefix
        self.blocks = blocks
    }
}

public enum CommandHistoryReconciler {
    public static func reconcile(capture: String, journal: [CommandBlock]) -> ReconciledCommandHistory {
        let capture = capture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capture.isEmpty, !journal.isEmpty else {
            return ReconciledCommandHistory(restoredPrefix: capture, blocks: [])
        }
        for offset in journal.indices {
            if let boundary = match(Array(journal[offset...]), in: capture) {
                let prefix = String(capture[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                return ReconciledCommandHistory(restoredPrefix: prefix, blocks: Array(journal[offset...]))
            }
        }
        return ReconciledCommandHistory(restoredPrefix: capture, blocks: [])
    }

    private static func match(_ blocks: [CommandBlock], in capture: String) -> String.Index? {
        var cursor = capture.startIndex
        var boundary: String.Index?
        for block in blocks {
            let tokens = [block.command, block.output].filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return nil }
            for token in tokens {
                guard let range = capture.range(of: token, range: cursor ..< capture.endIndex) else { return nil }
                boundary = boundary ?? range.lowerBound
                cursor = range.upperBound
            }
        }
        return boundary
    }
}
