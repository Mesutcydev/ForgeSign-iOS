import UIKit

/// Owns the semi-local OTA install flow:
/// local HTTP IPA server + remote HTTPS plist (`api.palera.in`) + Safari /
/// itms-services handoff. Shared by the Sign tab and the Library tab.
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

                // Confirm the local IPA endpoint answers before handing off.
                let health = URL(string: "\(server.installBaseURL)/health")!
                let (_, healthResp) = try await URLSession.shared.data(from: health)
                guard (healthResp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "forgesign.install", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Local install server failed self-check."])
                }

                // Confirm the remote HTTPS plist resolves (this is what iOS
                // actually fetches — must be trusted public HTTPS).
                guard let plistURL = URL(string: server.remoteManifestURL) else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
                }
                let (plistData, plistResp) = try await URLSession.shared.data(from: plistURL)
                guard (plistResp as? HTTPURLResponse)?.statusCode == 200,
                      let plistText = String(data: plistData, encoding: .utf8),
                      plistText.contains("software-package") else {
                    throw NSError(domain: "forgesign.install", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Remote manifest server unavailable. Check network and retry."])
                }

                // Open the local HTTP install page in Safari (no TLS warning).
                // The page redirects into itms-services with the remote HTTPS plist.
                guard let page = URL(string: "\(server.installBaseURL)/install") else {
                    throw NSError(domain: "forgesign.install", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad install page URL."])
                }
                installStatus = "Opening Safari… tap Install, keep ForgeSign open."
                UIApplication.shared.open(page) { [weak self] opened in
                    Task { @MainActor in
                        guard let self else { return }
                        if opened {
                            self.installStatus = "Safari opened. Tap Install / Accept, keep ForgeSign in the background."
                        } else if let itmsURL = URL(string: server.itmsServicesURL) {
                            self.installStatus = "Opening installer directly…"
                            UIApplication.shared.open(itmsURL)
                        }
                    }
                }

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

    /// Re-opens the local HTTP install page in Safari.
    func openInstallPage() {
        guard let server = installServer else { return }
        guard let page = URL(string: "\(server.installBaseURL)/install") else { return }
        installStatus = "Opening install page in Safari…"
        UIApplication.shared.open(page)
    }
}
