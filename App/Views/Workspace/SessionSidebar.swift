import PierApplication
import PierDomain
import SwiftUI

struct SessionSidebar: View {
    @Bindable var model: SessionModel
    let onSelectWindow: (TmuxWindow) -> Void

    var body: some View {
        List {
            ForEach(model.sessions) { session in
                Section {
                    ForEach(session.windows) { window in
                        Button {
                            select(window.id)
                        } label: {
                            HStack {
                                Label("\(window.index):\(window.name)", systemImage: "rectangle.on.rectangle")
                                Spacer()
                                Text("\(window.panes.count) panes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(model.selection?.windowID == window.id ? Color.accentColor : Color.primary)
                        .listRowBackground(
                            model.selection?.windowID == window.id ? Color.accentColor.opacity(0.1) : Color.clear
                        )
                        .accessibilityIdentifier("sidebar-window-\(window.id.rawValue)")
                    }
                } header: {
                    HStack {
                        Label(session.name, systemImage: "square.stack.3d.up")
                        Spacer()
                        Text("\(session.windows.count)w")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func select(_ id: WindowID?) {
        guard let id, let window = model.sessions.flatMap(\.windows).first(where: { $0.id == id }) else { return }
        onSelectWindow(window)
    }
}
