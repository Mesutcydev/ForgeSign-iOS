import SwiftUI

@main
struct ForgeSignMobileApp: App {
    @StateObject private var certificates = CertificateStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var history = HistoryStore()
    @StateObject private var installer = InstallController()

    var body: some Scene {
        WindowGroup {
            ForgeRootView()
                .environmentObject(certificates)
                .environmentObject(profiles)
                .environmentObject(history)
                .environmentObject(installer)
        }
    }
}

/// Root: Sign + Library tabs, theme injection + Dynamic Type cap.
/// The ambient glass backdrop is mounted inside each tab's NavigationStack.
private struct ForgeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installer: InstallController

    private var theme: ForgeTheme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        TabView {
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
