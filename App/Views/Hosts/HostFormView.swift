import PierDomain
import SwiftUI

struct HostFormView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let keys: [SSHKeyMetadata]
    let onSave: (PierDomain.Host) async throws -> Void
    @State private var name = ""; @State private var address = ""; @State private var username =
        ""; @State private var keyID: KeyID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("接続先") {
                    TextField("表示名", text: $name); TextField("ホスト名 / IP", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(); TextField(
                            "ユーザー",
                            text: $username
                        ).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("認証鍵") {
                    if keys.isEmpty {
                        Label("先にSSH鍵を生成してください", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if keys.count == 1, let key = keys.first {
                        LabeledContent("鍵") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(key.name)
                                Text(key.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Picker("鍵", selection: $keyID) {
                            Text("選択してください").tag(KeyID?.none)
                            ForEach(keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("ホストを追加").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }
                }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(keyID == nil) }
            }
            .onAppear { synchronizeKeySelection() }
            .onChange(of: keys) { _, _ in synchronizeKeySelection() }
        }
    }

    private func synchronizeKeySelection() {
        if keys.count == 1 {
            keyID = keys.first?.id
        } else if !keys.contains(where: { $0.id == keyID }) {
            keyID = nil
        }
    }

    private func save() {
        guard let keyID else { return }
        switch PierDomain.Host.parse(
            id: HostID(rawValue: container.identifierGenerator.makeUUID().uuidString),
            name: name,
            address: address,
            username: username,
            keyID: keyID
        ) {
        case let .failure(value):
            switch value {
            case .missingRequiredField:
                error = "表示名、ホスト名、ユーザーをすべて入力してください。"
            case .invalidAddress:
                error = "ホスト名またはIPアドレスに空白を含めることはできません。"
            }
        case let .success(host): Task {
                do { try await onSave(host); dismiss() } catch { self.error = UserFacingError.message(for: error) }
            }
        }
    }
}
