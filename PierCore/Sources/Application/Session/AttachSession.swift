import Foundation
import PierDomain

public enum AttachSessionStage: Equatable, Sendable {
    case startup
    case sessionTree
    case capture(PaneID)
    case shellIntegration(PaneID)
}

public enum AttachSessionError: Error, Equatable, LocalizedError, Sendable {
    case timedOut(stage: AttachSessionStage)
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(stage): "tmux attach timed out during \(stage)"
        case let .sessionNotFound(name): "Attached tmux session was not found: \(name)"
        }
    }
}

public enum PanePresentation: Equatable, Sendable {
    case shell
    case terminal
}

public struct RestoredPane: Equatable, Sendable {
    public let pane: Pane
    public let capture: Data
    public let presentation: PanePresentation

    public init(pane: Pane, capture: Data, presentation: PanePresentation) {
        self.pane = pane
        self.capture = capture
        self.presentation = presentation
    }
}

public struct AttachSessionOutcome: Equatable, Sendable {
    public let sessions: [TmuxSession]
    public let attachedSessionID: SessionID
    public let restoredPanes: [RestoredPane]
    public let connectionGeneration: TmuxConnectionGeneration

    public init(
        sessions: [TmuxSession],
        attachedSessionID: SessionID,
        restoredPanes: [RestoredPane],
        connectionGeneration: TmuxConnectionGeneration
    ) {
        self.sessions = sessions
        self.attachedSessionID = attachedSessionID
        self.restoredPanes = restoredPanes
        self.connectionGeneration = connectionGeneration
    }
}

public struct AttachSession: Sendable {
    private let timeout: SessionStageTimeout
    private let logger: any PierLogger

    public init(
        clock: any Clock,
        timeout: Duration = .seconds(10),
        logger: any PierLogger = NullLogger()
    ) {
        self.timeout = SessionStageTimeout(clock: clock, duration: timeout)
        self.logger = logger
    }

    public func callAsFunction(
        gateway: TmuxGateway,
        endpoint: SSHEndpoint,
        sessionName: String,
        lease: SessionOperationLease = SessionOperationLease()
    ) async throws -> AttachSessionOutcome {
        let connectionGeneration = try await within(.startup, gateway: gateway, lease: lease) {
            try await gateway.connect(endpoint: endpoint, sessionName: sessionName)
        }
        do {
            let sessions = try await within(.sessionTree, gateway: gateway, lease: lease) {
                try await LoadSessionTree()(gateway: gateway)
            }
            guard let attached = sessions.first(where: { $0.name == sessionName }) else {
                throw AttachSessionError.sessionNotFound(sessionName)
            }

            var restoredPanes: [RestoredPane] = []
            for pane in attached.windows.flatMap(\.panes) {
                let capture = try await within(.capture(pane.id), gateway: gateway, lease: lease) {
                    try await gateway.capturePane(pane.id)
                }
                let presentation: PanePresentation = TUIClassifier.isTUI(
                    pane,
                    detectedAlternateScreen: false
                ) ? .terminal : .shell
                restoredPanes.append(RestoredPane(pane: pane, capture: capture, presentation: presentation))
                if presentation == .shell {
                    try await within(.shellIntegration(pane.id), gateway: gateway, lease: lease) {
                        try await InstallShellIntegration()(gateway: gateway, pane: pane)
                    }
                }
            }
            try await lease.check()
            return AttachSessionOutcome(
                sessions: sessions,
                attachedSessionID: attached.id,
                restoredPanes: restoredPanes,
                connectionGeneration: connectionGeneration
            )
        } catch {
            await gateway.disconnect(if: connectionGeneration)
            throw error
        }
    }

    private func within<Value: Sendable>(
        _ stage: AttachSessionStage,
        gateway: TmuxGateway,
        lease: SessionOperationLease,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        logger.log(.debug, "Attach stage started: \(stage)")
        do {
            let value = try await timeout.run(
                stage: stage,
                lease: lease,
                onTimeout: { await gateway.disconnect() },
                operation: operation
            )
            logger.log(.debug, "Attach stage completed: \(stage)")
            return value
        } catch {
            logger.log(.error, "Attach stage failed [\(stage)]: \(error.localizedDescription)")
            throw error
        }
    }
}
