import PierDomain
import SwiftUI
import UIKit

struct KeyManagerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var stateMachine = KeyManagerStateMachine()
    @State private var reloadTask: Task<Void, Never>?
    @State private var name = "Pier Key"
    @State private var kind: SSHKeyKind = .secureEnclaveP256
    @State private var error: String?
    @State private var editingKey: SSHKeyMetadata?
    @State private var editedName = ""
    @State private var pendingDeletion: SSHKeyMetadata?
    @State private var isGenerating = false
    @State private var copiedKeyID: KeyID?
    let onChanged: () async -> Void

    var body: some View {
        NavigationStack {
            content
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("SSH鍵")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完了") { dismiss() } }
                .task { launchReload() }
                .onDisappear { reloadTask?.cancel() }
                .alert(
                    "鍵名を変更",
                    isPresented: Binding(
                        get: { editingKey != nil },
                        set: { if !$0 { editingKey = nil } }
                    )
                ) {
                    TextField("鍵の名前", text: $editedName)
                    Button("保存") { rename() }
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("キャンセル", role: .cancel) { editingKey = nil }
                }
                .alert(
                    "鍵を削除しますか？",
                    isPresented: Binding(
                        get: { pendingDeletion != nil },
                        set: { if !$0 { pendingDeletion = nil } }
                    ),
                    presenting: pendingDeletion
                ) { key in
                    Button("削除", role: .destructive) { remove(key) }
                    Button("キャンセル", role: .cancel) { pendingDeletion = nil }
                } message: { key in
                    Text("「\(key.name)」を削除します。この鍵を使用するホストには接続できなくなります。")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stateMachine.state {
        case .loading:
            ProgressView("SSH鍵を読み込んでいます…")
        case let .loaded(keys):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    newKeySection
                    HStack {
                        Text("保存済みの鍵").font(.subheadline.weight(.semibold))
                        Spacer()
                        if !keys.isEmpty {
                            Text("\(keys.count)件").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, -12)
                    savedKeysSection
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        case let .failed(message):
            ContentUnavailableView {
                Label("SSH鍵を読み込めませんでした", systemImage: "key")
            } description: {
                Text(message)
            } actions: {
                Button("再試行", action: launchReload)
            }
        }
    }
}

extension KeyManagerView {
    private var newKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新しい鍵").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                formRow("名前") {
                    TextField("Pier Key", text: $name)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 16)
                formRow("形式") {
                    Picker("形式", selection: $kind) {
                        ForEach(SSHKeyKind.allCases) { keyKind in
                            Text(keyKind.displayName).lineLimit(1).tag(keyKind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                }
                Divider().padding(.leading, 16)
                formRow("保護") {
                    Label(kind.storageName, systemImage: kind.storageSystemImage)
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 16)
                Button { generate() } label: {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                            Text("生成中")
                        } else {
                            Label("鍵を生成", systemImage: "key.horizontal.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isGenerating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            Text("形式に応じてSecure EnclaveまたはKeychainで保護されます。形式は生成後に変更できません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var savedKeysSection: some View {
        if keys.isEmpty {
            ContentUnavailableView(
                "鍵はまだありません",
                systemImage: "key",
                description: Text("上のフォームから最初の鍵を生成してください。")
            )
            .frame(minHeight: 180)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(keys) { key in
                    keyRow(key)
                }
            }
        }
    }

    private func formRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer(minLength: 16)
            content()
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
    }

    private func keyRow(_ key: SSHKeyMetadata) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key.name).font(.headline)
                        Text("\(key.kind.displayName) · \(key.kind.storageName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    keyMenu(key)
                }
                Text(key.publicKey)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(16)
            Divider().padding(.leading, 16)
            Button { copy(key) } label: {
                Label(
                    copiedKeyID == key.id ? "コピーしました" : "公開鍵をコピー",
                    systemImage: copiedKeyID == key.id ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var keys: [SSHKeyMetadata] {
        guard case let .loaded(keys) = stateMachine.state else { return [] }
        return keys
    }

    private func launchReload() {
        reloadTask?.cancel()
        let generation = stateMachine.begin()
        reloadTask = Task {
            do {
                let keys = try await container.listKeys()
                guard !Task.isCancelled else { return }
                if stateMachine.complete(keys: keys, generation: generation) {
                    await onChanged()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                stateMachine.fail(message: UserFacingError.message(for: error), generation: generation)
            }
        }
    }

    private func generate() {
        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                _ = try await container.generateKey(name: name, kind: kind)
                launchReload()
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    private func keyMenu(_ key: SSHKeyMetadata) -> some View {
        Menu {
            Button("名前を変更") {
                editedName = key.name
                editingKey = key
            }
            Button("削除", role: .destructive) {
                pendingDeletion = key
            }
        } label: {
            Label("鍵の操作", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private func copy(_ key: SSHKeyMetadata) {
        UIPasteboard.general.string = key.publicKey
        withAnimation(.easeOut(duration: 0.18)) { copiedKeyID = key.id }
        Task {
            do {
                try await Task.sleep(for: .seconds(1.5))
                guard copiedKeyID == key.id else { return }
                withAnimation(.easeOut(duration: 0.18)) { copiedKeyID = nil }
            } catch is CancellationError {
                return
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    private func rename() {
        guard let key = editingKey else { return }
        let newName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await container.renameKey(id: key.id, name: newName)
                editingKey = nil
                launchReload()
            } catch { self.error = UserFacingError.message(for: error) }
        }
    }

    private func remove(_ key: SSHKeyMetadata) {
        Task {
            do {
                try await container.removeKey(id: key.id)
                pendingDeletion = nil
                launchReload()
            } catch { self.error = UserFacingError.message(for: error) }
        }
    }
}
