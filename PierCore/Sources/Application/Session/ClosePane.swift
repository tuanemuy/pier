import PierDomain

public struct ClosePane: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, paneID: PaneID) async throws {
        _ = try await gateway.command("kill-pane -t \(paneID.rawValue)")
    }
}
