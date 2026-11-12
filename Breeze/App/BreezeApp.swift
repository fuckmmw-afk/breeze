import BreezeKit
import SwiftUI

@main
struct BreezeApp: App {
    @StateObject private var state = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let identity = SigningInfo.app().applicationIdentifier + "|" + TunnelManager.tunnelBundleIdentifier
        LibboxBootstrap.setCommandPort(LibboxBootstrap.derivePort(from: identity))
        LibboxBootstrap.setup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .tint(Theme.accent)
                .task {
                    await state.tunnel.load()
                    await state.autoUpdateIfNeeded()
                }
                .onOpenURL { url in
                    Task { await state.handle(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await state.tunnel.load()
                    state.publishIntegrations()
                }
            }
        }
    }
}
