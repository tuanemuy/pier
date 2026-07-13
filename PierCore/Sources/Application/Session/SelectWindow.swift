import PierDomain

public struct SelectWindow: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, windowID: WindowID) async throws {
        _ = try await gateway.command("select-window -t \(windowID.rawValue)")
    }
}
