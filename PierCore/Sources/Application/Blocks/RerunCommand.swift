import PierDomain

public struct RerunCommand: Sendable {
    public init() {}
    public func callAsFunction(_ block: CommandBlock, gateway: TmuxGateway, paneID: PaneID) async throws {
        try await RunCommand()(block.command, gateway: gateway, paneID: paneID)
    }
}
