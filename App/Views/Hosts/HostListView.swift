import PierApplication
import PierDomain
import SwiftUI

struct HostListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var settings
    @State private var stateMachine = HostListStateMachine()
    @State private var reloadTask: Task<Void, Never>?
    @State private var showingHostForm = false
    @State private var showingKeys = false
    @State private var showingSettings = false
    @State private var operationFailure: String?
    let onConnect: (HostConnection) -> Void

    var body: some View {
        NavigationStack {
            List {
                listContent
            }
            .navigationTitle("Pier")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("鍵", systemImage: "key") { showingKeys = true }
                    Button("設定", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("ホストを追加", systemImage: "plus", action: openHostForm)
                        .disabled(!isLoaded)
                }
            }
            .sheet(isPresented: $showingHostForm) { HostFormView(keys: loadedKeys) { host in
                try await container.registerHost(host)
                launchReload()
            } }
            .sheet(isPresented: $showingKeys) { KeyManagerView { launchReload() } }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .task { launchReload() }
            .onDisappear { reloadTask?.cancel() }
            .alert("操作に失敗しました", isPresented: operationFailureBinding) {
                Button("閉じる") { operationFailure = nil }
            } message: {
                Text(operationFailure ?? "")
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch stateMachine.state {
        case .loading:
            HStack {
                Spacer()
                ProgressView("ホストを読み込んでいます…")
                Spacer()
            }
        case let .loaded(hosts, _):
            if hosts.isEmpty {
                ContentUnavailableView(
                    "ホストがありません",
                    systemImage: "server.rack",
                    description: Text("鍵と接続先を登録すると、ここから1タップで接続できます。")
                )
            } else {
                ForEach(hosts) { host in
                    Button { onConnect(HostConnection(hostID: host.id.rawValue)) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "terminal.fill").font(.title2).foregroundStyle(settings.theme.accent)
                            VStack(alignment: .leading) {
                                Text(host.name).font(.headline); Text("\(host.username)@\(host.address)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("host-\(host.id.rawValue)")
                }.onDelete(perform: delete)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("ホストを読み込めませんでした", systemImage: "server.rack")
            } description: {
                Text(message)
            } actions: {
                Button("再試行", action: launchReload)
            }
        }
    }

    private func launchReload() {
        reloadTask?.cancel()
        let generation = stateMachine.begin()
        reloadTask = Task {
            do {
                async let hosts = container.listHosts()
                async let keys = container.listKeys()
                let (loadedHosts, loadedKeys) = try await (hosts, keys)
                guard !Task.isCancelled else { return }
                stateMachine.complete(hosts: loadedHosts, keys: loadedKeys, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                stateMachine.fail(message: UserFacingError.message(for: error), generation: generation)
            }
        }
    }

    private func openHostForm() {
        if case .loaded = stateMachine.state {
            showingHostForm = true
        }
    }

    private func delete(at offsets: IndexSet) {
        guard case let .loaded(hosts, _) = stateMachine.state else { return }
        let hostIDs = offsets.compactMap { hosts.indices.contains($0) ? hosts[$0].id : nil }
        Task {
            do {
                for hostID in hostIDs {
                    try await container.removeHost(id: hostID)
                }
                launchReload()
            } catch {
                operationFailure = UserFacingError.message(for: error)
            }
        }
    }

    private var loadedKeys: [SSHKeyMetadata] {
        guard case let .loaded(_, keys) = stateMachine.state else { return [] }
        return keys
    }

    private var isLoaded: Bool {
        if case .loaded = stateMachine.state { return true }
        return false
    }

    private var operationFailureBinding: Binding<Bool> {
        Binding(
            get: { operationFailure != nil },
            set: { if !$0 { operationFailure = nil } }
        )
    }
}
