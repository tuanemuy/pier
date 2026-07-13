import PierApplication
import PierDomain
import SwiftUI

struct WindowTabs: View {
    @Bindable var model: SessionModel
    let onSelect: (TmuxWindow) -> Void
    let onCreate: () -> Void
    let onClose: (WindowID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.selectedSession?.windows ?? []) { window in
                    windowTab(window)
                }
                Button("新規ウィンドウ", systemImage: "plus", action: onCreate)
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func windowTab(_ window: TmuxWindow) -> some View {
        let isSelected = model.selection?.windowID == window.id
        return Button {
            onSelect(window)
        } label: {
            Text("\(window.index):\(window.name)")
                .font(.caption.monospaced())
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("ウィンドウを閉じる", systemImage: "trash", role: .destructive) {
                onClose(window.id)
            }
        }
    }
}
