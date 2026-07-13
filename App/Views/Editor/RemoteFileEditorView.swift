import PierDomain
import SwiftUI
import UIKit

struct RemoteFileEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var state: RemoteFileEditorState = .loading
    @State private var loadGeneration: UInt64 = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                    if case let .loaded(file, draft, _) = state {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                save(file: file, draft: draft)
                            }
                        }
                    }
                }
                .task { await load() }
                .alert("保存できませんでした", isPresented: saveFailureBinding) {
                    Button("閉じる") { clearSaveFailure() }
                } message: {
                    Text(saveFailureMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("ファイルを開いています…")
        case .loaded:
            NativeTextEditor(
                text: draftBinding,
                font: settings.terminalFont.uiFont(size: settings.fontSize),
                isEditable: true
            )
        case .saving:
            NativeTextEditor(
                text: draftBinding,
                font: settings.terminalFont.uiFont(size: settings.fontSize),
                isEditable: false
            )
        case let .failed(message):
            ContentUnavailableView {
                Label("ファイルを開けませんでした", systemImage: "doc.badge.ellipsis")
            } description: {
                Text(message)
            } actions: {
                Button("再試行") { Task { await load() } }
                Button("閉じる") { dismiss() }
            }
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: {
                switch state {
                case let .loaded(_, draft, _), let .saving(_, draft):
                    draft
                case .loading, .failed:
                    ""
                }
            },
            set: { state.updateDraft($0) }
        )
    }

    private var saveFailureMessage: String? {
        guard case let .loaded(_, _, message) = state else { return nil }
        return message
    }

    private var saveFailureBinding: Binding<Bool> {
        Binding(
            get: { saveFailureMessage != nil },
            set: { if !$0 { clearSaveFailure() } }
        )
    }

    private func load() async {
        loadGeneration &+= 1
        let activeGeneration = loadGeneration
        state.beginLoading()
        do {
            let file = try await container.remoteFileEditor.open(path: path)
            guard activeGeneration == loadGeneration else { return }
            state.load(file)
        } catch is CancellationError {
            return
        } catch {
            guard activeGeneration == loadGeneration else { return }
            state.failLoading(message: UserFacingError.message(for: error))
        }
    }

    private func save(file: RemoteFile, draft: String) {
        state.beginSaving(file: file, draft: draft)
        Task {
            do {
                try await container.remoteFileEditor.save(file.editing(contents: draft))
                dismiss()
            } catch {
                state.failSaving(message: UserFacingError.message(for: error))
            }
        }
    }

    private func clearSaveFailure() {
        state.clearSaveFailure()
    }
}

struct NativeTextEditor: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let isEditable: Bool
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.delegate = context.coordinator; view.autocorrectionType = .no; view
            .smartQuotesType = .no; view.smartDashesType = .no; view.alwaysBounceVertical = true; view
            .keyboardDismissMode = .interactive; view.isEditable = isEditable; view.textContainerInset = UIEdgeInsets(
                top: 16,
                left: 12,
                bottom: 16,
                right: 12
            ); return view
    }

    func updateUIView(_ view: UITextView, context _: Context) {
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.font = font
        view.isEditable = isEditable
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
