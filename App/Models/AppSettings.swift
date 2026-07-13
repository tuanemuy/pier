import CoreText
import Observation
import SwiftUI
import UIKit

enum PierTheme: String, CaseIterable, Identifiable {
    case midnight, harbor, daylight
    var id: Self {
        self
    }

    var label: String {
        switch self {
        case .midnight: "Midnight"
        case .harbor: "Harbor"
        case .daylight: "Daylight"
        }
    }

    var colorScheme: ColorScheme {
        self == .daylight ? .light : .dark
    }

    var background: Color {
        switch self {
        case .midnight:
            Color(red: 0.043, green: 0.051, blue: 0.067)
        case .harbor:
            Color(
                red: 0.035,
                green: 0.08,
                blue: 0.10
            )
        case .daylight:
            Color(red: 0.95, green: 0.96, blue: 0.98)
        }
    }

    var panel: Color {
        switch self {
        case .midnight:
            Color(red: 0.071, green: 0.086, blue: 0.118)
        case .harbor:
            Color(
                red: 0.055,
                green: 0.13,
                blue: 0.15
            )
        case .daylight:
            .white
        }
    }

    var accent: Color {
        self == .harbor ? .cyan : Color(red: 0.435, green: 0.659, blue: 1)
    }
}

enum TerminalFont: String, CaseIterable, Identifiable {
    case jetBrains, system, menlo, courier
    var id: Self {
        self
    }

    var label: String {
        switch self {
        case .jetBrains: "JetBrains Mono"
        case .system: "System Mono"
        case .menlo: "Menlo"
        case .courier: "Courier"
        }
    }

    func font(size: Double) -> Font {
        if self == .system { return .system(size: size, design: .monospaced) }
        return .custom(postScriptName ?? "JetBrainsMono-Regular", size: size)
    }

    func uiFont(size: Double) -> UIFont {
        let base = postScriptName.flatMap { UIFont(name: $0, size: size) } ?? .monospacedSystemFont(
            ofSize: size,
            weight: .regular
        )
        let japanese = UIFont(name: "HiraginoSans-W3", size: size) ?? .systemFont(ofSize: size)
        let cascadeKey = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        let descriptor = base.fontDescriptor.addingAttributes([cascadeKey: [japanese.fontDescriptor]])
        return UIFont(descriptor: descriptor, size: size)
    }

    private var postScriptName: String? {
        switch self {
        case .jetBrains: "JetBrainsMono-Regular"
        case .system: nil
        case .menlo: "Menlo-Regular"
        case .courier: "Courier"
        }
    }
}

@Observable final class AppSettings {
    var theme: PierTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    var terminalFont: TerminalFont {
        didSet { UserDefaults.standard.set(terminalFont.rawValue, forKey: "terminalFont") }
    }

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }

    init() {
        theme = PierTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .midnight
        terminalFont = TerminalFont(rawValue: UserDefaults.standard.string(forKey: "terminalFont") ?? "") ?? .jetBrains
        let saved = UserDefaults.standard.double(forKey: "fontSize"); fontSize = saved == 0 ? 14 : saved
    }
}
