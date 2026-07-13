import PierDomain

public struct RunCommand: Sendable {
    public init() {}
    public func callAsFunction(
        _ command: String,
        gateway: TmuxGateway,
        paneID: PaneID,
        shell: String? = nil
    ) async throws {
        let source = shell.map { ShellCommandEnvelope.wrap(command, shell: $0) } ?? command
        try await SendKeys().literal(source + "\n", gateway: gateway, paneID: paneID)
    }
}

enum ShellCommandEnvelope {
    static func wrap(_ command: String, shell: String) -> String {
        switch shell {
        case "zsh", "bash", "sh":
            posix(command)
        case "fish":
            fish(command)
        default:
            command
        }
    }

    private static func posix(_ command: String) -> String {
        let source = TmuxGateway.quote(command)
        return "printf '\\033]133;C\\007'; eval \(source); __pier_status=$?; " +
            "printf '\\033]133;D;%d\\007\\033]133;A\\007\\033]133;B\\007' \"$__pier_status\"; " +
            "unset __pier_status"
    }

    private static func fish(_ command: String) -> String {
        let source = "'" + command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
        return "printf '\\033]133;C\\007'; eval \(source); set __pier_status $status; " +
            "printf '\\033]133;D;%d\\007\\033]133;A\\007\\033]133;B\\007' $__pier_status; " +
            "set -e __pier_status"
    }
}
