import Foundation
import PierApplication
import PierDomain
import SwiftUI

struct InputArea: View {
    @Environment(AppContainer.self) private var container
    let paneID: PaneID
    let currentDirectory: String
    let isTUI: Bool
    let onSubmit: (String) -> Void
    let onOpenFile: (String) -> Void
    @State private var input = ""
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            KeyAccessoryBar { key in
                Task {
                    do {
                        try await container.sessionCoordinator.sendNamedKey(key, paneID: paneID)
                    } catch {
                        self.error = UserFacingError.message(for: error)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Text(isTUI ? "⌨" : "❯").foregroundStyle(.blue).padding(.bottom, 9)
                TextField(isTUI ? "IMEで確定してキー送信" : "コマンド", text: $input, axis: .vertical).lineLimit(1 ... 4)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(send)
                    .accessibilityIdentifier("command-input")
                Button("送信", systemImage: "arrow.up.circle.fill", action: send).labelStyle(.iconOnly).font(.title2)
                    .disabled(input.isEmpty)
            }.padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
        }
        .alert("キーを送信できません", isPresented: .constant(error != nil)) { Button("閉じる") { error = nil } } message: {
            Text(error ?? "")
        }
    }

    private func send() {
        let value = input; input = ""
        if !isTUI, let path = editorPath(from: value) {
            onOpenFile(path)
        } else if isTUI {
            Task {
                do {
                    try await container.sessionCoordinator.sendLiteralKeys(value, paneID: paneID)
                } catch {
                    self.error = UserFacingError.message(for: error)
                }
            }
        } else {
            onSubmit(value)
        }
    }

    private func editorPath(from command: String) -> String? {
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, ["vim", "vi", "nano"].contains(parts[0]) else { return nil }
        return parts[1].hasPrefix("/") ? parts[1] : URL(fileURLWithPath: currentDirectory).appending(path: parts[1])
            .standardized.path
    }
}

struct KeyAccessoryBar: View {
    let send: (TmuxKey) -> Void
    @State private var controlArmed = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Button("ctrl") { controlArmed.toggle() }
                    .font(.caption.monospaced()).buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(controlArmed ? .blue : .secondary)
                ForEach(KeyAccessoryItem.all, id: \.label) { item in
                    Button(item.label) {
                        send(item.key(controlArmed: controlArmed))
                        controlArmed = false
                    }
                    .font(.caption.monospaced()).buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }.background(.thinMaterial)
    }
}

struct KeyAccessoryItem: Equatable {
    let label: String
    let normal: TmuxKey
    let controlled: TmuxKey

    func key(controlArmed: Bool) -> TmuxKey {
        controlArmed ? controlled : normal
    }

    static let all = [
        KeyAccessoryItem(label: "esc", normal: .escape, controlled: .control(.escape)),
        KeyAccessoryItem(label: "tab", normal: .tab, controlled: .control(.tab)),
        KeyAccessoryItem(label: "C-c", normal: .control(.letterC), controlled: .control(.letterC)),
        KeyAccessoryItem(label: "prefix", normal: .control(.letterB), controlled: .control(.letterB)),
        KeyAccessoryItem(label: "↑", normal: .arrow(.upward), controlled: .control(.upward)),
        KeyAccessoryItem(label: "↓", normal: .arrow(.downward), controlled: .control(.downward)),
        KeyAccessoryItem(label: "←", normal: .arrow(.leftward), controlled: .control(.leftward)),
        KeyAccessoryItem(label: "→", normal: .arrow(.rightward), controlled: .control(.rightward))
    ]
}
