import PierDomain
import SwiftUI
import UIKit

struct PaneContentView: View {
    @Environment(AppContainer.self) private var container
    let pane: Pane
    let blocks: [CommandBlock]
    let isTUI: Bool
    let onOpenFile: (String) -> Void
    let onRerun: (String) -> Void
    let onTerminalFailure: (Error) -> Void
    var body: some View {
        if !isTUI {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if blocks.isEmpty { Text("コマンドを入力してください").font(.callout).foregroundStyle(.secondary).padding(
                        .top,
                        30
                    ) }
                    ForEach(blocks) { block in CommandBlockView(
                        block: block,
                        workingDirectory: pane.currentPath,
                        onRerun: { onRerun(block.command) },
                        onOpenFile: onOpenFile
                    ) }
                }.padding(12)
            }
        } else {
            TerminalSurface(paneID: pane.id, columns: pane.width, onFailure: onTerminalFailure)
        }
    }
}

struct CommandBlockView: View {
    let block: CommandBlock
    let workingDirectory: String
    let onRerun: () -> Void
    let onOpenFile: (String) -> Void
    @State private var expanded = false
    private var exitCode: Int? {
        if case let .finished(code) = block.status { code } else { nil }
    }

    private var isRunning: Bool {
        block.status == .running
    }

    private var isRestored: Bool {
        block.status == .restored
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(isRestored ? .gray : (exitCode == nil ? .blue : (exitCode == 0 ? .green : .red)))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    if isRestored {
                        Label("復元されたスクロールバック", systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                    } else { Text("❯").foregroundStyle(.blue); Text(block.command).fontWeight(.semibold) }
                    Spacer()
                    if let exitCode {
                        Text("exit \(exitCode)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background((exitCode == 0 ? Color.green : .red).opacity(0.18), in: Capsule())
                    } else if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                if !block.output.isEmpty {
                    Text(block.output).lineLimit(expanded ? nil : 12).textSelection(.enabled)
                    if block.outputLines > 12 {
                        Button(expanded ? "折りたたむ" : "\(block.outputLines)行の出力 — 展開") { expanded.toggle() }
                            .font(.caption)
                    }
                    ForEach(outputFilePaths, id: \.self) { path in
                        Button(path, systemImage: "doc.text") { onOpenFile(path) }
                            .font(.caption.monospaced())
                    }
                }
                HStack {
                    if !isRestored {
                        Button("再実行", systemImage: "arrow.clockwise", action: onRerun)
                        Button("コマンド", systemImage: "doc.on.doc") { UIPasteboard.general.string = block.command }
                    }
                    if !block.output.isEmpty {
                        Button("出力", systemImage: "doc.on.doc.fill") { UIPasteboard.general.string = block.output }
                    }
                    Spacer()
                    if let duration = block.duration { Text(duration.formatted(.units(
                        allowed: [.seconds, .milliseconds],
                        width: .abbreviated
                    ))).font(.caption).foregroundStyle(.secondary) }
                }.labelStyle(.iconOnly)
            }.font(.system(.body, design: .monospaced)).padding(12)
        }.background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }

    private var outputFilePaths: [String] {
        var seen = Set<String>()
        return block.output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { token -> String? in
                let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}:,;"))
                guard candidate.count > 1, looksLikePath(candidate) else { return nil }
                let path = candidate.hasPrefix("/")
                    ? candidate
                    : (workingDirectory as NSString).appendingPathComponent(candidate)
                let normalized = (path as NSString).standardizingPath
                return seen.insert(normalized).inserted ? normalized : nil
            }
    }

    private func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") || value.contains("/") ||
            (value.contains(".") && !value.hasPrefix(".") && !value.contains("="))
    }
}
