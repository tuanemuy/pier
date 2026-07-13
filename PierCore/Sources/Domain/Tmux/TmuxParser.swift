import Foundation

public enum TmuxParser {
    public static func parse(_ bytes: Data) -> Result<TmuxMessage, TmuxParseError> {
        let bytes = normalizeControlModeEnvelope(bytes)
        let outputPrefix = Data("%output ".utf8)
        if bytes.starts(with: outputPrefix) {
            let body = bytes.dropFirst(outputPrefix.count)
            guard let separator = body.firstIndex(of: 32) else {
                return .failure(.malformed(replacingInvalidUTF8(in: bytes)))
            }
            let paneBytes = body[..<separator]
            guard let rawPaneID = String(bytes: paneBytes, encoding: .utf8),
                  case let .success(paneID) = PaneID.parse(rawPaneID)
            else {
                return .failure(.malformed(replacingInvalidUTF8(in: bytes)))
            }
            let payloadStart = body.index(after: separator)
            let payload = Data(body[payloadStart...])
            switch decodeOutput(payload) {
            case let .success(data):
                return .success(.output(paneID: paneID, data: data))
            case let .failure(error):
                return .failure(error)
            }
        }
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            if bytes.first == 37 {
                return .failure(.invalidUTF8)
            }
            return .success(.responseLine(replacingInvalidUTF8(in: bytes)))
        }
        return parse(line)
    }

    public static func parse(_ line: String) -> Result<TmuxMessage, TmuxParseError> {
        let line = normalizeControlModeEnvelope(line)
        guard line.hasPrefix("%") else { return .success(.responseLine(line)) }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let keyword = parts.first else { return .failure(.malformed(line)) }
        switch keyword {
        case "%begin", "%end", "%error":
            return parseTransaction(keyword: keyword, parts: parts, line: line)
        case "%output":
            guard parts.count == 3 else { return .failure(.malformed(line)) }
            guard case let .success(paneID) = PaneID.parse(parts[1]) else {
                return .failure(.malformed(line))
            }
            switch decodeOutput(parts[2]) {
            case let .success(data): return .success(.output(paneID: paneID, data: data))
            case let .failure(error): return .failure(error)
            }
        case "%window-add":
            guard parts.count >= 2, case let .success(windowID) = WindowID.parse(parts[1]) else {
                return .failure(.malformed(line))
            }
            return .success(.windowAdded(windowID))
        case "%window-close":
            guard parts.count >= 2, case let .success(windowID) = WindowID.parse(parts[1]) else {
                return .failure(.malformed(line))
            }
            return .success(.windowClosed(windowID))
        case "%window-renamed":
            guard parts.count == 3, case let .success(windowID) = WindowID.parse(parts[1]) else {
                return .failure(.malformed(line))
            }
            return .success(.windowRenamed(windowID: windowID, name: parts[2]))
        case "%layout-change":
            guard parts.count == 3, case let .success(windowID) = WindowID.parse(parts[1]) else {
                return .failure(.malformed(line))
            }
            return .success(.layoutChanged(windowID: windowID, layout: parts[2]))
        case "%session-changed":
            guard parts.count == 3, case let .success(sessionID) = SessionID.parse(parts[1]) else {
                return .failure(.malformed(line))
            }
            return .success(.sessionChanged(sessionID: sessionID, name: parts[2]))
        case "%sessions-changed": return .success(.sessionsChanged)
        case "%exit": return .success(.exit(reason: parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil))
        default: return .success(.unknown(line))
        }
    }

    private static func parseTransaction(
        keyword: String,
        parts: [String],
        line: String
    ) -> Result<TmuxMessage, TmuxParseError> {
        guard parts.count == 3 else { return .failure(.malformed(line)) }
        let tail = parts[2].split(separator: " ").map(String.init)
        guard tail.count == 2,
              let timestamp = UInt64(parts[1]),
              let command = UInt64(tail[0]),
              let flags = Int(tail[1])
        else {
            return .failure(.malformed(line))
        }
        switch keyword {
        case "%begin":
            return .success(.begin(timestamp: timestamp, commandNumber: command, flags: flags))
        case "%end":
            return .success(.end(timestamp: timestamp, commandNumber: command, flags: flags))
        default:
            return .success(.commandError(timestamp: timestamp, commandNumber: command, flags: flags))
        }
    }

    private static func normalizeControlModeEnvelope(_ line: String) -> String {
        let start = "\u{1B}P1000p"
        let end = "\u{1B}\\"
        var normalized = line
        if let range = normalized.range(of: start) {
            normalized = String(normalized[range.upperBound...])
        }
        if normalized.hasSuffix(end) {
            normalized.removeLast(end.count)
        }
        return normalized
    }

    private static func normalizeControlModeEnvelope(_ bytes: Data) -> Data {
        let start = Data("\u{1B}P1000p".utf8)
        let end = Data("\u{1B}\\".utf8)
        var normalized = bytes
        if let range = normalized.range(of: start) {
            normalized = normalized.subdata(in: range.upperBound ..< normalized.endIndex)
        }
        if normalized.count >= end.count, normalized.suffix(end.count) == end {
            normalized.removeLast(end.count)
        }
        return normalized
    }

    public static func decodeOutput(_ value: String) -> Result<Data, TmuxParseError> {
        decodeOutput(Data(value.utf8))
    }

    private static func decodeOutput(_ value: Data) -> Result<Data, TmuxParseError> {
        let bytes = Array(value)
        var result = Data(); result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 92 {
                guard index + 3 < bytes.count else {
                    return .failure(.invalidOctalEscape(replacingInvalidUTF8(in: value)))
                }
                let digits = bytes[(index + 1) ... (index + 3)]
                guard digits.allSatisfy({ (48 ... 55).contains($0) })
                else {
                    return .failure(.invalidOctalEscape(replacingInvalidUTF8(in: value)))
                }
                let decoded = (digits[digits.startIndex] - 48) * 64 +
                    (digits[digits.index(after: digits.startIndex)] - 48) * 8 + (digits[digits.index(
                        digits.startIndex,
                        offsetBy: 2
                    )] - 48)
                result.append(decoded); index += 4
            } else { result.append(bytes[index]); index += 1 }
        }
        return .success(result)
    }

    private static func replacingInvalidUTF8(in bytes: some Collection<UInt8>) -> String {
        // Replacement is the explicit policy for non-structural terminal bytes and parse diagnostics.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
