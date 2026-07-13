import Foundation
import PierSupport

public struct DiscoverSessions: Sendable {
    private static let missingTmuxMarker = "__PIER_TMUX_MISSING__"
    static let ensureDefaultSessionCommand =
        "tmux has-session -t '=main' 2>/dev/null || " +
        "tmux new-session -d -s main 2>/dev/null || tmux has-session -t '=main'"

    public init() {}

    public func callAsFunction(transport: any TransportPort, endpoint: SSHEndpoint) async throws -> [String] {
        let data = try await transport.executeIdempotent(
            "if command -v tmux >/dev/null 2>&1; then " +
                "tmux list-sessions -F '#{session_name}' 2>/dev/null || true; " +
                "else printf '\(Self.missingTmuxMarker)\\n'; fi",
            at: endpoint
        )
        guard let output = String(data: data, encoding: .utf8) else {
            throw PierError.invalidResponse("Session discovery response contains invalid UTF-8")
        }
        let lines = output.split(separator: "\n").map(String.init)
        guard !lines.contains(Self.missingTmuxMarker) else {
            throw PierError.unavailable("接続先にtmuxがインストールされていません。tmuxをインストールしてから再試行してください。")
        }
        let sessions = lines.filter { !$0.isEmpty }
        guard sessions.isEmpty else { return sessions }
        _ = try await transport.executeIdempotent(Self.ensureDefaultSessionCommand, at: endpoint)
        return ["main"]
    }
}
