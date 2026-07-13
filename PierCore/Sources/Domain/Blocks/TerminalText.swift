import Foundation

public enum TerminalText {
    public static func plain(_ data: Data) -> String {
        var decoder = IncrementalTerminalTextDecoder()
        return decoder.consume(data, boundary: true)
    }
}

struct IncrementalTerminalTextDecoder {
    private var controlBuffer = Data()
    private var utf8Buffer = Data()

    mutating func consume(_ data: Data, boundary: Bool) -> String {
        controlBuffer.append(data)
        let plainBytes = removeControlSequences(boundary: boundary)
        utf8Buffer.append(plainBytes)
        let splitIndex = boundary ? utf8Buffer.endIndex : completeUTF8Boundary(in: utf8Buffer)
        let complete = Data(utf8Buffer[..<splitIndex])
        utf8Buffer.removeSubrange(..<splitIndex)
        if boundary, !utf8Buffer.isEmpty {
            let remainder = utf8Buffer
            utf8Buffer.removeAll(keepingCapacity: true)
            return Self.decodeReplacingInvalid(complete + remainder)
        }
        return Self.decodeReplacingInvalid(complete)
    }

    private mutating func removeControlSequences(boundary: Bool) -> Data {
        var result = Data()
        var index = controlBuffer.startIndex
        var incompleteStart: Data.Index?
        scan: while index < controlBuffer.endIndex {
            guard controlBuffer[index] == 0x1B else {
                if controlBuffer[index] != 0x0D { result.append(controlBuffer[index]) }
                index = controlBuffer.index(after: index)
                continue
            }
            let following = controlBuffer.index(after: index)
            guard following < controlBuffer.endIndex else {
                incompleteStart = index
                break
            }
            switch controlBuffer[following] {
            case 0x5B:
                guard let end = csiEnd(after: following) else {
                    incompleteStart = index
                    break scan
                }
                index = controlBuffer.index(after: end)
            case 0x5D:
                guard let end = oscEnd(after: following) else {
                    incompleteStart = index
                    break scan
                }
                index = end
            default:
                index = controlBuffer.index(after: following)
            }
        }
        if let incompleteStart, !boundary {
            controlBuffer = Data(controlBuffer[incompleteStart...])
        } else {
            controlBuffer.removeAll(keepingCapacity: true)
        }
        return result
    }

    private func csiEnd(after introducer: Data.Index) -> Data.Index? {
        var index = controlBuffer.index(after: introducer)
        while index < controlBuffer.endIndex {
            if (0x40 ... 0x7E).contains(controlBuffer[index]) { return index }
            index = controlBuffer.index(after: index)
        }
        return nil
    }

    private func oscEnd(after introducer: Data.Index) -> Data.Index? {
        var index = controlBuffer.index(after: introducer)
        while index < controlBuffer.endIndex {
            if controlBuffer[index] == 0x07 { return controlBuffer.index(after: index) }
            if controlBuffer[index] == 0x1B {
                let following = controlBuffer.index(after: index)
                if following < controlBuffer.endIndex, controlBuffer[following] == 0x5C {
                    return controlBuffer.index(after: following)
                }
            }
            index = controlBuffer.index(after: index)
        }
        return nil
    }

    private func completeUTF8Boundary(in data: Data) -> Data.Index {
        guard !data.isEmpty else { return data.endIndex }
        var start = data.index(before: data.endIndex)
        while start > data.startIndex, Self.isContinuation(data[start]) {
            start = data.index(before: start)
        }
        guard let expected = Self.utf8Length(leadingByte: data[start]) else { return data.endIndex }
        let available = data.distance(from: start, to: data.endIndex)
        return available < expected ? start : data.endIndex
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80 ... 0xBF).contains(byte)
    }

    private static func utf8Length(leadingByte: UInt8) -> Int? {
        switch leadingByte {
        case 0x00 ... 0x7F: 1
        case 0xC2 ... 0xDF: 2
        case 0xE0 ... 0xEF: 3
        case 0xF0 ... 0xF4: 4
        default: nil
        }
    }

    private static func decodeReplacingInvalid(_ bytes: some Collection<UInt8>) -> String {
        // Replacement is the explicit policy for malformed terminal bytes.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
