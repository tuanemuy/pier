import PierDomain

public struct SplitPane: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, paneID: PaneID, direction: Direction) async throws {
        _ = try await gateway.command(PaneGrid(panes: []).splitCommand(paneID: paneID, toward: direction))
    }
}
