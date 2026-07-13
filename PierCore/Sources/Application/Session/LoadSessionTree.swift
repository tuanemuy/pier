import PierDomain

public struct LoadSessionTree: Sendable {
    public init() {}

    public func callAsFunction(gateway: TmuxGateway) async throws -> [TmuxSession] {
        let windowLines = try await gateway.command("list-windows -a -F '\(SessionTreeRecordFormat.windows)'")
        let paneLines = try await gateway.command("list-panes -a -F '\(SessionTreeRecordFormat.panes)'")
        return try SessionTreeResponseParser.parse(windowLines: windowLines, paneLines: paneLines)
    }
}
