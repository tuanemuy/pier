import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("テーマ") { Picker("カラーテーマ", selection: $settings.theme) { ForEach(PierTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                } }.pickerStyle(.inline) }
                Section("ターミナルとエディタ") {
                    Picker("フォント", selection: $settings.terminalFont) { ForEach(TerminalFont.allCases) { font in
                        Text(font.label).tag(font)
                    } }
                    HStack {
                        Text("サイズ"); Slider(value: $settings.fontSize, in: 8 ... 28,
                                            step: 1); Text("\(Int(settings.fontSize))").monospacedDigit()
                    }
                    Text("日本語 ABC　全角2幅 123").font(settings.terminalFont.font(size: settings.fontSize)).padding(
                        .vertical,
                        8
                    )
                }
            }.navigationTitle("設定").toolbar { Button("完了") { dismiss() } }
        }
    }
}
