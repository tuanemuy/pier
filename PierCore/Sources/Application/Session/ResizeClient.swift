public struct ResizeClient: Sendable {
    public init() {}
    public func callAsFunction(gateway: TmuxGateway, columns: Int, rows: Int) async throws {
        guard columns > 0, rows > 0 else { return }
        _ = try await gateway.command("refresh-client -C \(columns),\(rows)")
    }
}
