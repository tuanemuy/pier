import PierApplication
import PierDomain
import SwiftUI

struct WorkspaceDetailView: View {
    @Bindable var model: SessionModel
    let host: PierDomain.Host
    let sessionName: String
    let onDisconnect: () -> Void
    let onSelectWindow: (TmuxWindow) -> Void
    let onCreateWindow: () -> Void
    let onCloseWindow: (WindowID) -> Void
    let onSelectPane: (PaneID) -> Void
    let onSplitPane: (PaneID, Direction) -> Void
    let onClosePane: (PaneID) -> Void
    let onMovePane: (PaneID, WindowID) -> Void
    let onOpenFile: (String) -> Void
    let onSubmit: (String, PaneID) -> Void
    let onTerminalFailure: (Error) -> Void
    let onReload: () async -> Void
    @State private var isSidebarPresented = false
    @State private var isDisconnectConfirmationPresented = false

    var body: some View {
        ZStack(alignment: .leading) {
            workspace
                .allowsHitTesting(!isSidebarPresented)

            if isSidebarPresented {
                sidebarDrawer
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isSidebarPresented)
        .confirmationDialog(
            "SSH接続を終了しますか？",
            isPresented: $isDisconnectConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("接続を終了", role: .destructive, action: onDisconnect)
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            workspaceHeader
            WindowTabs(
                model: model,
                onSelect: onSelectWindow,
                onCreate: onCreateWindow,
                onClose: onCloseWindow
            )
            paneContent
        }
    }

    private var sidebarDrawer: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    sidebarHeader
                    SessionSidebar(model: model) { window in
                        onSelectWindow(window)
                        isSidebarPresented = false
                    }
                }
                .frame(width: min(320, proxy.size.width * 0.8))
                .background(.background)
                .safeAreaPadding(.top)
                .safeAreaPadding(.bottom)

                Button {
                    isSidebarPresented = false
                } label: {
                    Color.black.opacity(0.45)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("サイドバーを閉じる")
                .accessibilityIdentifier("sidebar-dismiss-area")
            }
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }

    private var sidebarHeader: some View {
        HStack {
            Text("セッション")
                .font(.headline)
            Spacer()
            Button("サイドバーを閉じる", systemImage: "sidebar.left") {
                isSidebarPresented = false
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .accessibilityIdentifier("sidebar-close-button")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var paneContent: some View {
        if let window = model.selectedWindow, let selection = model.selection {
            PaneDeckView(
                window: window,
                selectedPaneID: selection.paneID,
                destinations: model.sessions.flatMap(\.windows).filter { $0.id != window.id },
                onSelect: onSelectPane,
                onSplit: onSplitPane,
                onClose: onClosePane,
                onMove: onMovePane
            ) { pane in
                PaneContentView(
                    pane: pane,
                    blocks: model.blocks[pane.id] ?? [],
                    isTUI: model.isTUI(pane),
                    onOpenFile: onOpenFile,
                    onRerun: { onSubmit($0, pane.id) },
                    onTerminalFailure: onTerminalFailure
                )
            }
            InputArea(
                paneID: selection.paneID,
                currentDirectory: model.selectedPane?.currentPath ?? "~",
                isTUI: model.selectedPane.map(model.isTUI) ?? false,
                onSubmit: { onSubmit($0, selection.paneID) },
                onOpenFile: onOpenFile
            )
        } else {
            ContentUnavailableView("ペインがありません", systemImage: "rectangle.split.2x1")
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Button("セッション一覧", systemImage: "line.3.horizontal") {
                isSidebarPresented = true
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(width: 40, height: 40)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("workspace-sidebar-button")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(model.selectedSession?.name ?? sessionName)
                        .font(.headline)
                        .lineLimit(1)
                    if let windowName = model.selectedWindow?.name {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(windowName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                    Text("\(host.address) · \(connectionStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("再読み込み", systemImage: "arrow.clockwise") {
                    Task { await onReload() }
                }
                Divider()
                Button("接続を終了", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    isDisconnectConfirmationPresented = true
                }
            } label: {
                Label("接続メニュー", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .accessibilityIdentifier("workspace-connection-menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var connectionStatus: String {
        switch model.connection {
        case .connected:
            "tmux -CC 接続中"
        case .connecting:
            "接続中"
        case let .reconnecting(attempt):
            "再接続中（\(attempt)回目）"
        case .disconnected:
            "切断"
        case .failed:
            "接続エラー"
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected:
            .green
        case .connecting, .reconnecting:
            .orange
        case .disconnected, .failed:
            .red
        }
    }
}
