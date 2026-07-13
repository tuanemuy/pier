import PierDomain

public struct CloseWindow: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, windowID: WindowID) async throws {
        _ = try await gateway.command("kill-window -t \(windowID.rawValue)")
    }
}
