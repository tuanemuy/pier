import PierDomain

public struct SendKeys: Sendable {
    public init() {}
    public func literal(_ text: String, gateway: TmuxGateway, paneID: PaneID) async throws {
        _ = try await gateway.command("send-keys -t \(paneID.rawValue) -l \(TmuxGateway.quote(text))")
    }

    public func named(_ key: TmuxKey, gateway: TmuxGateway, paneID: PaneID) async throws {
        _ = try await gateway.command("send-keys -t \(paneID.rawValue) \(key.commandToken)")
    }
}
