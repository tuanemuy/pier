import PierDomain

public struct ZoomPane: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, paneID: PaneID) async throws {
        _ = try await gateway.command(
            "if-shell -F -t \(paneID.rawValue) '#{window_zoomed_flag}' '' 'resize-pane -Z -t \(paneID.rawValue)'"
        )
    }
}
