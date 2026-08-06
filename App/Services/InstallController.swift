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

                // Best-effort self-check. URLSession and the iOS OTA installer
                // use different TLS stacks — a URLSession failure here must not
                // abort the install (that was masking a working itms-services
                // handoff with "A TLS error caused the secure connection to fail").
                let base = server.installBaseURL
                if let checkURL = URL(string: "\(base)/manifest.plist") {
                    do {
                        let (_, resp) = try await URLSession.shared.data(from: checkURL)
                        if (resp as? HTTPURLResponse)?.statusCode != 200 {
                            installStatus = "Local server self-check returned a non-200; trying installer anyway…"
                        }
                    } catch {
                        installStatus = "Self-check skipped (\(error.localizedDescription)). Triggering installer…"
                    }
                }

                // On iOS 18+, UIApplication.open(itms-services://) often returns
                // success without ever showing the install prompt (no entitlement).
                // Always hand off through Safari: the local /install page redirects
                // into itms-services, which is the path Feather and other on-device
                // installers rely on.
                guard let page = URL(string: "\(base)/install") else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad install page URL."])
                }
                installStatus = "Opening Safari… tap Install, then keep ForgeSign open."
                UIApplication.shared.open(page) { [weak self] opened in
                    Task { @MainActor in
                        guard let self else { return }
                        if opened {
                            self.installStatus = "Safari opened. Tap Install / Accept, and keep ForgeSign in the background."
                        } else {
                            // Last resort: try the raw itms-services URL.
                            self.installStatus = "Safari blocked — trying direct installer…"
                            if let itmsURL = URL(string: server.itmsServicesURL) {
                                UIApplication.shared.open(itmsURL)
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
