import SwiftUI

@main
struct ForgeSignMobileApp: App {
    @StateObject private var certificates = CertificateStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var history = HistoryStore()
    @StateObject private var installer = InstallController()
    @StateObject private var sources = SourceStore()

    var body: some Scene {
        WindowGroup {
            ForgeRootView()
                .environmentObject(certificates)
                .environmentObject(profiles)
                .environmentObject(history)
                .environmentObject(installer)
                .environmentObject(sources)
        }
    }
}

private struct ForgeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installer: InstallController

    private var theme: ForgeTheme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        TabView {
            AppsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }

            ContentView()
                .tabItem { Label("Sign", systemImage: "signature") }

            LibraryView { record in
                installer.install(ipa: history.outputURL(for: record),
                                  bundleId: record.bundleId,
                                  version: record.version)
            }
            .tabItem { Label("Library", systemImage: "clock.arrow.circlepath") }
        }
        .tint(theme.accent)
        .forgeTheme(theme)
        .forgeScaledType()
    }
}
