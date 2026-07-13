import PierDomain
import SwiftUI

struct PaneDeckView<Content: View>: View {
    let window: TmuxWindow
    let selectedPaneID: PaneID
    let destinations: [TmuxWindow]
    let onSelect: (PaneID) -> Void
    let onSplit: (PaneID, Direction) -> Void
    let onClose: (PaneID) -> Void
    let onMove: (PaneID, WindowID) -> Void
    @ViewBuilder let content: (Pane) -> Content
    @State private var translation: CGSize = .zero
    @State private var pendingClose: Pane?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(window.panes.enumerated()), id: \.element.id) { index, pane in
                    let selected = pane.id == selectedPaneID
                    card(pane, selected: selected).frame(
                        width: max(1, geometry.size.width - 16 - (selected ? 0 : 52)),
                        height: max(1, geometry.size.height - 16 - (selected ? 0 : 26))
                    )
                    .offset(selected ? translation : peekOffset(pane, index: index))
                    .zIndex(selected ? 100 : Double(index))
                    .onTapGesture { onSelect(pane.id) }
                    .contextMenu {
                        Button("閉じる", systemImage: "xmark", role: .destructive) {
                            if isBusy(pane) { pendingClose = pane } else { onClose(pane.id) }
                        }
                        Menu("別ウィンドウへ移動", systemImage: "arrow.right.square") {
                            ForEach(destinations) { destination in
                                Button("\(destination.index):\(destination.name)") {
                                    onMove(pane.id, destination.id)
                                }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 18).onChanged { translation = $0.translation }
                    .onEnded(handleDrag))
        }
        .confirmationDialog(
            "実行中のプロセスを閉じますか？",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })
        ) {
            Button("ペインを閉じる", role: .destructive) { if let pane = pendingClose { onClose(pane.id) }; pendingClose = nil
            }
            Button("キャンセル", role: .cancel) { pendingClose = nil }
        } message: { Text("ペイン内の \(pendingClose?.currentCommand ?? "プロセス") も終了します。") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-deck")
    }

    private func card(_ pane: Pane, selected: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(pane.id.rawValue)
                    .foregroundStyle(.blue); Text(pane.title.isEmpty ? pane.currentCommand : pane
                        .title); Spacer(); Circle()
                    .fill(selected ? .green : .secondary).frame(
                        width: 7,
                        height: 7
                    )
            }.font(.caption.monospaced()).padding(.horizontal, 12).frame(height: 40).background(.thinMaterial)
            if selected { content(pane).clipped() } else { Color.clear }
        }
        .background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 18)).shadow(
            color: .black.opacity(0.42),
            radius: 22,
            y: 12
        ).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    private func peekOffset(_ pane: Pane, index: Int) -> CGSize {
        guard let selected = window.panes.first(where: { $0.id == selectedPaneID }) else { return .zero }
        let horizontalOffset: CGFloat = pane.position.x == selected.position
            .x ? 0 : (pane.position.x < selected.position.x ? -24 : 24)
        let verticalOffset: CGFloat = pane.position.y == selected.position
            .y ? 0 : (pane.position.y < selected.position.y ? -14 : 14)
        let depth = CGFloat(index % 3) * 3
        return CGSize(width: horizontalOffset + depth, height: verticalOffset + depth)
    }

    private func handleDrag(_ value: DragGesture.Value) {
        defer { withAnimation(.spring(response: 0.3)) { translation = .zero } }
        guard hypot(value.translation.width, value.translation.height) > 70 else { return }
        let direction: Direction = abs(value.translation.width) > abs(value.translation.height) ?
            (value.translation.width > 0 ? .rightward : .leftward) :
            (value.translation.height > 0 ? .downward : .upward)
        let grid = PaneGrid(panes: window.panes)
        if let neighbor = grid.pane(from: selectedPaneID, toward: direction) { onSelect(neighbor.id) } else { onSplit(
            selectedPaneID,
            direction
        ) }
    }

    private func isBusy(_ pane: Pane) -> Bool {
        !["sh", "bash", "zsh", "fish", "nu"].contains(pane.currentCommand)
    }
}
