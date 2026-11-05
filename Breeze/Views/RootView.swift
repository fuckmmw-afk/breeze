import SwiftUI

enum AppTab: Hashable {
    case home
    case servers
    case subscriptions
    case settings
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Главная", systemImage: "shield.lefthalf.filled") }
                .tag(AppTab.home)
            ServersView()
                .tabItem { Label("Серверы", systemImage: "globe.europe.africa.fill") }
                .tag(AppTab.servers)
            SubscriptionsView()
                .tabItem { Label("Подписки", systemImage: "square.stack.3d.up.fill") }
                .tag(AppTab.subscriptions)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ToastView(text: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation(.snappy) { state.toast = nil } }
            }
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.label)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            .padding(.horizontal, 24)
    }
}
