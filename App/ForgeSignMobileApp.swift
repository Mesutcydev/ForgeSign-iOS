import SwiftUI

@main
struct ForgeSignMobileApp: App {
    @StateObject private var certificates = CertificateStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var history = HistoryStore()
    @StateObject private var installer = InstallController()
    @StateObject private var repositories = RepositoryStore()
    @StateObject private var imports = ImportRouter()

    var body: some Scene {
        WindowGroup {
            ForgeRootView()
                .environmentObject(certificates)
                .environmentObject(profiles)
                .environmentObject(history)
                .environmentObject(installer)
                .environmentObject(repositories)
                .environmentObject(imports)
                .onOpenURL { imports.receive($0) }
        }
    }
}

/// Root: Sign + Library tabs, theme injection + Dynamic Type cap.
/// The ambient glass backdrop is mounted inside each tab's NavigationStack.
private struct ForgeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installer: InstallController
    @EnvironmentObject private var repositories: RepositoryStore

    @State private var tab = 0

    private var theme: ForgeTheme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("Sign", systemImage: "signature") }
                .tag(0)

            SourcesView()
                .tabItem { Label("Sources", systemImage: "square.stack.3d.up") }
                .tag(1)

            LibraryView { record in
                history.setInstallState(.installing, for: record.id)
                installer.install(ipa: history.outputURL(for: record),
                                  bundleId: record.bundleId,
                                  version: record.version,
                                  recordID: record.id)
            }
            .tabItem { Label("Library", systemImage: "clock.arrow.circlepath") }
            .tag(2)
        }
        .tint(theme.accent)
        .forgeTheme(theme)
        .forgeScaledType()
        .onReceive(NotificationCenter.default.publisher(for: .forgeInstallState)) { notification in
            guard let payload = notification.userInfo,
                  let id = payload["recordID"] as? UUID,
                  let rawState = payload["state"] as? String,
                  let state = SigningRecord.InstallState(rawValue: rawState) else { return }
            history.setInstallState(state, for: id)
        }
        .onChange(of: repositories.pendingIPA) { ipa in
            // A repo download finished — surface it in the Sign tab.
            if ipa != nil { tab = 0 }
        }
    }
}
