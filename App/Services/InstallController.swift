import UIKit

/// Owns the semi-local OTA install flow (local HTTP IPA + remote HTTPS
/// plist via `api.palera.in`). Opens `itms-services` directly for a seamless
/// install prompt (1.0 behaviour); Safari is the fallback only.
@MainActor
final class InstallController: ObservableObject {
    @Published var installServer: LocalInstallServer?
    @Published var installStatus = ""

    /// Called when the currently served IPA has been fully downloaded.
    var onDelivered: (() -> Void)?

    private var foregroundObserver: (any NSObjectProtocol)?

    /// Tracks whether the current install delivered its IPA yet.
    private var delivered = false

    /// Coming back to the foreground while a server is still up but nothing was
    /// downloaded means the installer is not pulling anymore — release the
    /// silent-audio keep-alive so we don't hold the audio background mode.
    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.installServer != nil, !self.delivered else { return }
                InstallKeepAlive.shared.stop()
                if self.installStatus.hasPrefix("Install prompted") {
                    self.installStatus = "Back in ForgeSign. If no dialog appeared, try “Retry via Safari”."
                }
            }
        }
    }

    private func endObservation() {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    func install(ipa: URL, bundleId: String, version: String) {
        installStatus = "Starting install server…"
        delivered = false
        observeForeground()

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
                        guard let self else { return }
                        self.delivered = true
                        self.endObservation()
                        self.installStatus = "IPA delivered. Installing… accept the iOS prompt if shown."
                        InstallKeepAlive.shared.stop()
                        self.onDelivered?()
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

                // 1.0-style seamless handoff: open itms-services directly so iOS
                // shows the install prompt in-place. The manifest is remote
                // HTTPS (api.palera.in) — trusted — while the IPA stays on
                // local HTTP. Safari is only a fallback if the direct open is
                // gated.
                guard let itmsURL = URL(string: server.itmsServicesURL) else {
                    throw NSError(domain: "forgesign.install", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
                }
                installStatus = "Triggering installer…"
                UIApplication.shared.open(itmsURL) { [weak self] opened in
                    Task { @MainActor in
                        guard let self else { return }
                        if opened {
                            self.installStatus = "Install prompted. Accept the iOS dialog and keep ForgeSign open."
                        } else {
                            self.installStatus = "Direct open gated — opening Safari install page…"
                            if let page = URL(string: "\(server.installBaseURL)/install") {
                                UIApplication.shared.open(page)
                            }
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            } catch {
                delivered = false
                endObservation()
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
