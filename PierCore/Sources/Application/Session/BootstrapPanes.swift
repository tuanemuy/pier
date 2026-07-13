import Foundation
import PierDomain

public struct BootstrapPanes: Sendable {
    private let timeout: SessionStageTimeout

    public init(clock: any Clock, timeout: Duration = .seconds(10)) {
        self.timeout = SessionStageTimeout(clock: clock, duration: timeout)
    }

    public func callAsFunction(
        gateway: TmuxGateway,
        panes: [Pane],
        lease: SessionOperationLease
    ) async throws -> [RestoredPane] {
        let generation = try await gateway.connectedGeneration()
        do {
            var restored: [RestoredPane] = []
            for pane in panes {
                let capture = try await within(
                    .capture(pane.id),
                    gateway: gateway,
                    generation: generation,
                    lease: lease
                ) {
                    try await gateway.capturePane(pane.id)
                }
                let presentation: PanePresentation = TUIClassifier.isTUI(
                    pane,
                    detectedAlternateScreen: false
                ) ? .terminal : .shell
                restored.append(RestoredPane(pane: pane, capture: capture, presentation: presentation))
                if presentation == .shell {
                    try await within(
                        .shellIntegration(pane.id),
                        gateway: gateway,
                        generation: generation,
                        lease: lease
                    ) {
                        try await InstallShellIntegration()(gateway: gateway, pane: pane)
                    }
                }
            }
            try await lease.check()
            return restored
        } catch {
            await gateway.disconnect(if: generation)
            throw error
        }
    }

    private func within<Value: Sendable>(
        _ stage: AttachSessionStage,
        gateway: TmuxGateway,
        generation: TmuxConnectionGeneration,
        lease: SessionOperationLease,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await timeout.run(
            stage: stage,
            lease: lease,
            onTimeout: { await gateway.disconnect(if: generation) },
            operation: operation
        )
    }
}
