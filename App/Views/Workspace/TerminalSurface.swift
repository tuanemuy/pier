import PierApplication
import PierDomain
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalSurface: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var settings
    let paneID: PaneID
    let columns: Int
    let onFailure: (Error) -> Void
    @State private var baseSize: Double?
    @State private var fittedSize: Double?
    @State private var hasPinchOverride = false
    var body: some View {
        GeometryReader { geometry in
            SwiftTermView(
                paneID: paneID,
                store: container.terminalStore,
                sessionCoordinator: container.sessionCoordinator,
                onFailure: onFailure,
                font: uiFont,
                theme: settings.theme
            )
            .background(.black)
            .onAppear { fitFont(to: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in fitFont(to: width) }
            .onChange(of: columns) { _, _ in fitFont(to: geometry.size.width) }
            .gesture(MagnifyGesture().onChanged { value in
                if baseSize == nil { baseSize = fittedSize ?? settings.fontSize }
                hasPinchOverride = true
                let size = min(28, max(8, (baseSize ?? settings.fontSize) * value.magnification))
                fittedSize = size
                settings.fontSize = size
            }.onEnded { _ in baseSize = nil })
        }
    }

    private var uiFont: UIFont {
        settings.terminalFont.uiFont(size: fittedSize ?? settings.fontSize)
    }

    private func fitFont(to width: CGFloat) {
        guard !hasPinchOverride, width > 0 else { return }
        let targetColumns = columns > 1 ? columns : 80
        let unitFont = settings.terminalFont.uiFont(size: 1)
        let unitWidth = ("M" as NSString).size(withAttributes: [.font: unitFont]).width
        guard unitWidth > 0 else { return }
        fittedSize = min(28, max(8, width / CGFloat(targetColumns) / unitWidth))
    }
}

private struct SwiftTermView: UIViewRepresentable {
    private enum TerminalInputError: Error {
        case invalidUTF8
    }

    let paneID: PaneID
    let store: TerminalStore
    let sessionCoordinator: SessionCoordinator
    let onFailure: (Error) -> Void
    let font: UIFont
    let theme: PierTheme
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: font)
        view.nativeBackgroundColor = UIColor(theme.background)
        view.nativeForegroundColor = theme == .daylight ? .black : .white
        view.installColors(Self.palette(theme))
        context.coordinator.theme = theme
        view.isOpaque = true
        view.terminalDelegate = context.coordinator
        context.coordinator.start(
            paneID: paneID,
            store: store,
            sessionCoordinator: sessionCoordinator,
            onFailure: onFailure,
            terminal: view
        )
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        view.font = font
        view.nativeBackgroundColor = UIColor(theme.background)
        view.nativeForegroundColor = theme == .daylight ? .black : .white
        if context.coordinator.theme != theme {
            view.installColors(Self.palette(theme)); context.coordinator.theme = theme
        }
        if context.coordinator.paneID != paneID { context.coordinator.start(
            paneID: paneID,
            store: store,
            sessionCoordinator: sessionCoordinator,
            onFailure: onFailure,
            terminal: view
        ) }
    }

    static func dismantleUIView(_: TerminalView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor final class Coordinator: @preconcurrency TerminalViewDelegate {
        var paneID: PaneID?
        var theme: PierTheme?
        var task: Task<Void, Never>?
        private var sessionCoordinator: SessionCoordinator?
        private var onFailure: ((Error) -> Void)?

        func start(
            paneID: PaneID,
            store: TerminalStore,
            sessionCoordinator: SessionCoordinator,
            onFailure: @escaping (Error) -> Void,
            terminal: TerminalView
        ) {
            task?.cancel(); self.paneID = paneID; terminal.getTerminal().resetToInitialState()
            self.sessionCoordinator = sessionCoordinator
            self.onFailure = onFailure
            task = Task { @MainActor [weak terminal] in
                for await event in await store.stream(for: paneID) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .data(data):
                        let bytes = Array(data)
                        terminal?.feed(byteArray: bytes[...])
                    case .reset:
                        terminal?.getTerminal().resetToInitialState()
                    }
                }
            }
        }

        func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
            guard let sessionCoordinator else { return }
            perform { try await sessionCoordinator.resize(columns: newCols, rows: newRows) }
        }

        func send(source _: TerminalView, data: ArraySlice<UInt8>) {
            guard let sessionCoordinator, let paneID else { return }
            guard let value = String(bytes: data, encoding: .utf8) else {
                onFailure?(TerminalInputError.invalidUTF8)
                return
            }
            perform { try await sessionCoordinator.sendLiteralKeys(value, paneID: paneID) }
        }

        func setTerminalTitle(source _: TerminalView, title _: String) {}
        func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}
        func scrolled(source _: TerminalView, position _: Double) {}
        func requestOpenLink(source _: TerminalView, link _: String, params _: [String: String]) {}
        func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}

        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            Task {
                do {
                    try await operation()
                } catch {
                    onFailure?(error)
                }
            }
        }
    }

    private static func palette(_ theme: PierTheme) -> [SwiftTerm.Color] {
        let values: [Int] = switch theme {
        case .midnight:
            midnightPalette
        case .harbor:
            harborPalette
        case .daylight:
            daylightPalette
        }
        return values.map { value in
            SwiftTerm.Color(
                red: UInt16((value >> 16) & 0xFF) * 257,
                green: UInt16((value >> 8) & 0xFF) * 257,
                blue: UInt16(value & 0xFF) * 257
            )
        }
    }

    private static let midnightPalette = [
        0x0B0D11,
        0xE06C75,
        0x4FBE8B,
        0xE0AC5F,
        0x6FA8FF,
        0xB48EFD,
        0x56B6C2,
        0xC9D4E3,
        0x68738A,
        0xFF7A84,
        0x67D7A3,
        0xF2C675,
        0x8AB9FF,
        0xC6A7FF,
        0x75D1DC,
        0xE8EDF4
    ]

    private static let harborPalette = [
        0x071419,
        0xE76F79,
        0x46C9A3,
        0xE5B85C,
        0x51A8D8,
        0xB68AE8,
        0x3CCBD4,
        0xC8E1E5,
        0x557A80,
        0xFF8991,
        0x64E2BD,
        0xF4CB78,
        0x73C5F2,
        0xCDA7F5,
        0x62E4EC,
        0xECFAFC
    ]

    private static let daylightPalette = [
        0x20242A,
        0xC33C54,
        0x14805E,
        0x9A6700,
        0x245DAD,
        0x7B4AB0,
        0x087F8C,
        0xD9DEE7,
        0x687180,
        0xE04F67,
        0x1A9C73,
        0xB67B00,
        0x3478D4,
        0x9565C6,
        0x1599A6,
        0xFFFFFF
    ]
}
