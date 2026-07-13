import SwiftUI

@main
struct PierApp: App {
    @State private var container = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        ? AppContainer.preview()
        : AppContainer.live()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .environment(container.settings)
        }
    }
}
