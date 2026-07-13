import PierDomain

public struct ListSessions: Sendable {
    public init() {}

    public func callAsFunction(gateway: TmuxGateway) async throws -> [(id: SessionID, name: String)] {
        let lines = try await gateway.command("list-sessions -F '#{session_id}\t#{session_name}'")
        return try lines.map { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, case let .success(sessionID) = SessionID.parse(parts[0]) else {
                throw TmuxParseError.malformed(line)
            }
            return (sessionID, parts[1])
        }
    }
}
