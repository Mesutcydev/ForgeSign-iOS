import SwiftUI

@main
struct ForgeSignMobileApp: App {
    @StateObject private var certificates = CertificateStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var history = HistoryStore()
    @StateObject private var installCoordinator = InstallCoordinator()
    @StateObject private var repositories = RepositoryStore()
    @StateObject private var imports = ImportRouter()
    @StateObject private var refreshSources = RefreshSourceStore()

    var body: some Scene {
        WindowGroup {
            ForgeRootView()
                .environmentObject(certificates)
                .environmentObject(profiles)
                .environmentObject(history)
                .environmentObject(installCoordinator)
                .environmentObject(installCoordinator.controller)
                .environmentObject(repositories)
                .environmentObject(imports)
                .environmentObject(refreshSources)
                .onOpenURL { imports.receive($0) }
        }
    }
}

/// Root: Sign + Library tabs, theme injection + Dynamic Type cap.
/// The ambient glass backdrop is mounted inside each tab's NavigationStack.
private struct ForgeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installCoordinator: InstallCoordinator
    @EnvironmentObject private var repositories: RepositoryStore
    @EnvironmentObject private var imports: ImportRouter
    @EnvironmentObject private var refreshSources: RefreshSourceStore

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

            LibraryView(onInstall: { record in
                installCoordinator.install(ipa: history.outputURL(for: record),
                                           bundleId: record.bundleId,
                                           version: record.version,
                                           recordID: record.id,
                                           displayName: record.outputName)
            }, onRefresh: { record in
                // Refresh starts from the package that was originally imported —
                // never from the signed artifact — and re-enters the Sign tab so
                // the same assets and verification run again.
                if let source = refreshSources.sourceURL(for: record.id) {
                    imports.receive(source)
                }
                tab = 0
            })
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
