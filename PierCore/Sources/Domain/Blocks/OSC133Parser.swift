import Foundation

public struct OSC133Parser: Sendable {
    public enum Event: Equatable, Sendable {
        case promptStarted
        case commandStarted
        case commandFinished(exitCode: Int)
        case output(String)
    }

    private var buffer = Data()
    private var capturing = false
    private var textDecoder = IncrementalTerminalTextDecoder()
    public init() {}

    public mutating func consume(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        let prefix = Data([0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B])
        while let markerStart = buffer.range(of: prefix) {
            let before = buffer[..<markerStart.lowerBound]
            if capturing {
                let text = textDecoder.consume(Data(before), boundary: true)
                if !text.isEmpty { events.append(.output(text)) }
            }
            buffer.removeSubrange(..<markerStart.upperBound)
            guard let terminator = Self.terminator(in: buffer) else {
                buffer.insert(contentsOf: prefix, at: buffer.startIndex)
                return events
            }
            guard let payload = String(
                bytes: buffer[..<terminator.lowerBound],
                encoding: .utf8
            ) else {
                buffer.removeSubrange(..<terminator.upperBound)
                continue
            }
            buffer.removeSubrange(..<terminator.upperBound)
            let fields = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "A": events.append(.promptStarted)
            case "C":
                capturing = true
                textDecoder = IncrementalTerminalTextDecoder()
                events.append(.commandStarted)
            case "D":
                capturing = false
                textDecoder = IncrementalTerminalTextDecoder()
                events.append(.commandFinished(exitCode: fields.count > 1 ? Int(fields[1]) ?? -1 : 0))
            case "B", .none: break
            case .some: break
            }
        }
        if capturing, !buffer.isEmpty {
            let hold = Self.partialPrefixLength(buffer, prefix: prefix)
            let flushCount = buffer.count - hold
            if flushCount > 0 {
                let boundary = buffer.index(buffer.startIndex, offsetBy: flushCount)
                let text = textDecoder.consume(Data(buffer[..<boundary]), boundary: false)
                if !text.isEmpty { events.append(.output(text)) }
                buffer.removeSubrange(..<boundary)
            }
        }
        return events.filter(Self.shouldEmit)
    }

    private static func shouldEmit(_ event: Event) -> Bool {
        if case let .output(text) = event { return !text.isEmpty }
        return true
    }

    private static func terminator(in data: Data) -> Range<Data.Index>? {
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x07 { return index ..< data.index(after: index) }
            if data[index] == 0x1B, isStringTerminator(at: index, in: data) {
                return index ..< data.index(index, offsetBy: 2)
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func isStringTerminator(at escape: Data.Index, in data: Data) -> Bool {
        let following = data.index(after: escape)
        return following < data.endIndex && data[following] == 0x5C
    }

    private static func partialPrefixLength(_ data: Data, prefix: Data) -> Int {
        let maximum = min(data.count, prefix.count - 1)
        return stride(from: maximum, through: 1, by: -1)
            .first { data.suffix($0).elementsEqual(prefix.prefix($0)) } ?? 0
    }
}
