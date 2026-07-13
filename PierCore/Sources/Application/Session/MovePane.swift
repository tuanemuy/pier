import PierDomain

public struct MovePane: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, paneID: PaneID, destination: WindowID) async throws {
        _ = try await gateway.command("join-pane -s \(paneID.rawValue) -t \(destination.rawValue)")
    }
}
