import PierDomain

public struct SwitchSession: Sendable {
    public init() {}

    public func callAsFunction(gateway: TmuxGateway, sessionID: SessionID) async throws {
        _ = try await gateway.command("switch-client -t \(sessionID.rawValue)")
    }
}
