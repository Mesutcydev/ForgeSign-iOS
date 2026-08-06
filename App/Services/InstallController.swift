import UIKit

/// Owns the local OTA install flow (loopback HTTPS server + itms-services
/// handoff). Shared by the Sign tab and the Library tab.
@MainActor
final class InstallController: ObservableObject {
    @Published var installServer: LocalInstallServer?
    @Published var installStatus = ""

    /// Called when the currently served IPA has been fully downloaded.
    var onDelivered: (() -> Void)?

    func install(ipa: URL, bundleId: String, version: String) {
        installStatus = "Starting install server…"

        // Keep the app (and its local server) alive while the iOS installer
        // downloads. A background task alone only buys ~30 seconds; silent
        // audio playback holds the `audio` background mode for large IPAs.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "forgesign.install") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        InstallKeepAlive.shared.start()

        Task {
            do {
                installServer?.stop()
                let server = LocalInstallServer()
                _ = try await server.start(ipa: ipa, bundleId: bundleId,
                                           bundleVersion: version,
                                           title: ipa.deletingPathExtension().lastPathComponent)
                installServer = server
                server.onIPADelivered = { [weak self] in
                    Task { @MainActor in
                        self?.installStatus = "IPA delivered. Installing… accept the iOS prompt if shown."
                        InstallKeepAlive.shared.stop()
                        self?.onDelivered?()
                    }
                }

                // Self-check: confirm the HTTPS server is actually serving the
                // manifest before handing off to the installer.
                let base = server.installBaseURL
                let checkURL = URL(string: "\(base)/manifest.plist")!
                let (_, resp) = try await URLSession.shared.data(from: checkURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "forgesign.install", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Local server self-check failed."])
                }

                guard let itmsURL = URL(string: server.itmsServicesURL) else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
                }
                installStatus = "Server ready. Triggering installer…"
                UIApplication.shared.open(itmsURL) { [weak self] opened in
                    Task { @MainActor in
                        guard let self else { return }
                        if opened {
                            self.installStatus = "Install triggered. Accept the iOS prompt and keep ForgeSign open."
                        } else {
                            // Some iOS versions gate direct itms-services opens.
                            // Open the local install page in Safari instead; it
                            // redirects into the installer.
                            self.installStatus = "Opening install page in Safari… tap Install if asked."
                            if let page = URL(string: "\(base)/install") {
                                UIApplication.shared.open(page)
                            }
                        }
                    }
                }
                // Hold background execution while the download is in flight;
                // the keep-alive stops itself once the IPA has been delivered.
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            } catch {
                installStatus = "Install failed: \(error.localizedDescription)"
                installServer?.stop()
                installServer = nil
                InstallKeepAlive.shared.stop()
            }
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
    }

    /// Opens the local HTTPS install page in Safari. Used when iOS declines the
    /// direct `itms-services://` open (gated on newer iOS versions without the
    /// required entitlements); the page itself redirects into the installer.
    func openInstallPage() {
        guard let server = installServer else { return }
        guard let page = URL(string: "\(server.installBaseURL)/install") else { return }
        installStatus = "Opening install page in Safari…"
        UIApplication.shared.open(page)
    }
}
