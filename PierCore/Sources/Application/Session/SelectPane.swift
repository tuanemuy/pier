import PierDomain

public struct SelectPane: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, paneID: PaneID) async throws {
        _ = try await gateway.command("select-pane -t \(paneID.rawValue)")
    }
}
