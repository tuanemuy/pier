import PierDomain

public struct InstallShellIntegration: Sendable {
    public init() {}

    public func callAsFunction(gateway: TmuxGateway, pane: Pane) async throws {
        let script: String? = switch pane.currentCommand {
        case "zsh": Self.zshIntegration
        case "bash": Self.bashIntegration
        case "fish": Self.fishIntegration
        case "sh", "nu": nil
        default: nil
        }
        guard let script else { return }
        try await SendKeys().literal(script, gateway: gateway, paneID: pane.id)
        try await SendKeys().named(.enter, gateway: gateway, paneID: pane.id)
    }

    private static let zshIntegration = [
        "autoload -Uz add-zsh-hook; function _pier_preexec(){ printf '\\e]133;C\\a' };",
        "function _pier_precmd(){ local s=$?; printf '\\e]133;D;%d\\a\\e]133;A\\a\\e]133;B\\a' $s };",
        "add-zsh-hook -d preexec _pier_preexec 2>/dev/null; add-zsh-hook -d precmd _pier_precmd 2>/dev/null;",
        "add-zsh-hook preexec _pier_preexec; add-zsh-hook precmd _pier_precmd"
    ].joined(separator: " ")

    private static let bashIntegration = [
        "__pier_preexec(){ [[ $PIER_RUNNING == 1 ]] && return; PIER_RUNNING=1; printf '\\e]133;C\\a'; };",
        "trap '__pier_preexec' DEBUG;",
        "PROMPT_COMMAND='s=$?; printf \\\"\\e]133;D;%d\\a\\e]133;A\\a\\e]133;B\\a\\\" $s; PIER_RUNNING=0'"
    ].joined(separator: " ")

    private static let fishIntegration = [
        "functions -e __pier_preexec __pier_prompt;",
        "function __pier_preexec --on-event fish_preexec; printf '\\e]133;C\\a'; end;",
        "function __pier_prompt --on-event fish_prompt;",
        "printf '\\e]133;D;%s\\a\\e]133;A\\a\\e]133;B\\a' $status; end"
    ].joined(separator: " ")
}
