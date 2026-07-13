import PierApplication
import PierDomain
import SwiftUI

struct WorkspaceView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var preparation = WorkspacePreparationMachine()
    @State private var chosenSession: String?
    @State private var attachGeneration: UInt64 = 0
    @State private var operationFailure: String?
    @State private var editorRoute: EditorRoute?
    let connection: HostConnection
    let onDisconnect: () -> Void

    private var coordinator: SessionCoordinator {
        container.sessionCoordinator
    }

    private var model: SessionModel {
        coordinator.model
    }

    var body: some View {
        Group {
            preparationContent
        }
        .background(settings.theme.background.ignoresSafeArea())
        .task { await prepare() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                Task { await coordinator.suspend() }
            case .active:
                Task { await resume() }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .sheet(item: $editorRoute) { route in RemoteFileEditorView(path: route.path) }
        .alert("操作に失敗しました", isPresented: presenceBinding($operationFailure)) {
            Button("閉じる") { operationFailure = nil }
            Button("ホスト一覧へ") { disconnect() }
        } message: {
            Text(operationFailure ?? "")
        }
    }

    @ViewBuilder
    private var preparationContent: some View {
        switch preparation.state {
        case .idle, .discovering:
            ProgressView("ホストを読み込んでいます…")
        case let .loaded(host, sessions):
            if let chosenSession {
                sessionContent(host: host, sessionName: chosenSession)
            } else {
                SessionChooser(
                    sessions: sessions,
                    onChoose: { chooseSession($0, host: host) },
                    onCancel: disconnect
                )
            }
        case let .failed(message):
            setupFailureView(message)
        }
    }

    @ViewBuilder
    private func sessionContent(host: PierDomain.Host, sessionName: String) -> some View {
        switch model.connection {
        case .connecting:
            ProgressView("tmuxセッションに接続しています…")
        case let .failed(failure):
            ContentUnavailableView {
                Label("接続できませんでした", systemImage: "exclamationmark.triangle")
            } description: {
                Text(UserFacingError.message(for: failure))
            } actions: {
                Button("再試行") { Task { await attach() } }
                Button("セッションを選び直す") { chooseAnotherSession() }
            }
        case .disconnected:
            ProgressView("再接続を準備しています…")
        case .connected, .reconnecting:
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "セッション情報がありません",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("tmuxセッションを再読み込みしてください。")
                )
            } else {
                WorkspaceDetailView(
                    model: model,
                    host: host,
                    sessionName: sessionName,
                    onDisconnect: disconnect,
                    onSelectWindow: selectWindow,
                    onCreateWindow: createWindow,
                    onCloseWindow: closeWindow,
                    onSelectPane: selectPane,
                    onSplitPane: splitPane,
                    onClosePane: closePane,
                    onMovePane: movePane,
                    onOpenFile: { editorRoute = EditorRoute(path: $0) },
                    onSubmit: submit,
                    onTerminalFailure: report,
                    onReload: reload
                )
            }
        }
    }

    private func setupFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("ホストを読み込めませんでした", systemImage: "server.rack")
        } description: {
            Text(message)
        } actions: {
            Button("再試行") { Task { await prepare() } }
            Button("ホスト一覧へ", action: disconnect)
        }
    }

    private func prepare() async {
        attachGeneration &+= 1
        chosenSession = nil
        let activeGeneration = preparation.begin()
        await coordinator.disconnect()
        do {
            guard let value = try await container.resolveHost(id: HostID(rawValue: connection.hostID)) else {
                preparation.fail(message: "選択したホストが見つかりません。", generation: activeGeneration)
                return
            }
            let endpoint = SSHEndpoint(address: value.address, username: value.username, keyID: value.keyID)
            let sessions = try await DiscoverSessions()(transport: container.transport, endpoint: endpoint)
            preparation.complete(host: value, sessions: sessions, generation: activeGeneration)
        } catch is CancellationError {
            return
        } catch {
            preparation.fail(message: UserFacingError.message(for: error), generation: activeGeneration)
        }
    }

    private func chooseSession(_ name: String, host: PierDomain.Host) {
        attachGeneration &+= 1
        let activeGeneration = attachGeneration
        chosenSession = name
        Task { await attach(host: host, sessionName: name, generation: activeGeneration) }
    }

    private func attach() async {
        guard case let .loaded(host, _) = preparation.state, let chosenSession else { return }
        attachGeneration &+= 1
        let activeGeneration = attachGeneration
        await attach(host: host, sessionName: chosenSession, generation: activeGeneration)
    }

    private func attach(host: PierDomain.Host, sessionName: String, generation: UInt64) async {
        do {
            try await coordinator.attach(
                endpoint: SSHEndpoint(address: host.address, username: host.username, keyID: host.keyID),
                sessionName: sessionName
            )
            guard generation == attachGeneration else { return }
        } catch is CancellationError {
            return
        } catch {
            guard generation == attachGeneration else { return }
        }
    }

    private func resume() async {
        do {
            try await coordinator.resume()
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func chooseAnotherSession() {
        attachGeneration &+= 1
        Task {
            await coordinator.disconnect()
            chosenSession = nil
        }
    }

    private func disconnect() {
        Task {
            await coordinator.disconnect()
            onDisconnect()
        }
    }

    private func createWindow() {
        Task {
            do {
                try await coordinator.createWindow()
            } catch {
                report(error)
            }
        }
    }

    private func closeWindow(_ id: WindowID) {
        perform { try await coordinator.closeWindow(id) }
    }

    private func selectWindow(_ window: TmuxWindow) {
        Task {
            do {
                try await coordinator.selectWindow(window.id)
            } catch {
                report(error)
            }
        }
    }

    private func selectPane(_ id: PaneID) {
        Task {
            do {
                try await coordinator.selectPane(id)
            } catch {
                report(error)
            }
        }
    }

    private func splitPane(_ id: PaneID, _ direction: Direction) {
        perform { try await coordinator.splitPane(id, direction: direction) }
    }

    private func closePane(_ id: PaneID) {
        perform { try await coordinator.closePane(id) }
    }

    private func movePane(_ id: PaneID, _ window: WindowID) {
        perform { try await coordinator.movePane(id, destination: window) }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                report(error)
            }
        }
    }

    private func reload() async {
        do {
            try await coordinator.reloadSessionTree()
        } catch {
            report(error)
        }
    }

    private func submit(_ command: String, paneID: PaneID) {
        Task {
            do {
                try await coordinator.runCommand(command, paneID: paneID)
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        operationFailure = UserFacingError.message(for: error)
    }
}

private func presenceBinding(_ value: Binding<String?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { if !$0 { value.wrappedValue = nil } }
    )
}

struct EditorRoute: Identifiable {
    let path: String
    var id: String {
        path
    }
}
