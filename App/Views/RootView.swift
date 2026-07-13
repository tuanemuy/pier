import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var settings
    @State private var selectedHost: HostConnection?
    var body: some View {
        Group {
            if let selectedHost {
                WorkspaceView(connection: selectedHost) { self.selectedHost = nil }
            } else {
                HostListView { selectedHost = $0 }
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .tint(settings.theme.accent)
        .background(settings.theme.background)
    }
}

struct HostConnection: Equatable {
    let hostID: String
}
