import SwiftUI

struct SessionChooser: View {
    let sessions: [String]
    let onChoose: (String) -> Void
    let onCancel: () -> Void
    @State private var newName = "main"
    var body: some View {
        NavigationStack {
            List {
                Section("既存のセッション") { ForEach(sessions, id: \.self) { name in Button { onChoose(name) } label: { Label(
                    name,
                    systemImage: "rectangle.stack"
                ) }.accessibilityIdentifier("session-\(name)") } }
                Section("新しいセッション") {
                    HStack {
                        TextField("セッション名", text: $newName)
                            .textInputAutocapitalization(.never); Button("作成") { onChoose(newName) }
                            .disabled(newName.isEmpty)
                    }
                }
            }.navigationTitle("tmuxセッション").toolbar { ToolbarItem(placement: .cancellationAction) { Button(
                "ホスト一覧",
                systemImage: "chevron.left",
                action: onCancel
            ) } }
        }
    }
}
