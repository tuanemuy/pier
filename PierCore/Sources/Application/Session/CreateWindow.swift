import PierDomain

public struct CreateWindow: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, sessionID: SessionID) async throws {
        _ = try await gateway.command("new-window -t \(sessionID.rawValue)")
    }
}
