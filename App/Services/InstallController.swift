import UIKit

/// Owns the semi-local OTA install flow and one active operation at a time.
@MainActor
final class InstallController: ObservableObject {
    @Published var installServer: LocalInstallServer?
    @Published var installStatus = ""

    var onDelivered: (() -> Void)?

    private struct Operation {
        let id: UUID
        let recordID: UUID?
        var server: LocalInstallServer?
        var task: Task<Void, Never>?
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        var delivered = false
    }

    private var operation: Operation?
    private var foregroundObserver: (any NSObjectProtocol)?

    private func observeForeground(for id: UUID) {
        endObservation()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.operation?.id == id, self.operation?.delivered == false else { return }
                InstallKeepAlive.shared.stop()
                if self.installStatus.hasPrefix("Install prompted") {
                    self.installStatus = "Back in ForgeSign. If no dialog appeared, try “Retry via Safari”."
                }
            }
        }
    }

    private func endObservation() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    func install(ipa: URL, bundleId: String, version: String, recordID: UUID? = nil) {
        cancelInstall(markFailed: false)
        let id = UUID()
        var newOperation = Operation(id: id, recordID: recordID)
        installStatus = "Starting install server…"
        observeForeground(for: id)
        newOperation.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "forgesign.install") { [weak self] in
            Task { @MainActor in self?.cancelInstall(markFailed: true) }
        }
        operation = newOperation
        if let recordID {
            NotificationCenter.default.post(name: .forgeInstallState, object: nil,
                                            userInfo: ["recordID": recordID, "state": SigningRecord.InstallState.installing.rawValue])
        }
        InstallKeepAlive.shared.start()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let server = LocalInstallServer()
                _ = try await server.start(ipa: ipa, bundleId: bundleId, bundleVersion: version,
                                           title: ipa.deletingPathExtension().lastPathComponent)
                try Task.checkCancellation()
                guard self.operation?.id == id else {
                    server.stop()
                    return
                }
                self.operation?.server = server
                self.installServer = server
                server.onIPADelivered = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.operation?.id == id, self.operation?.delivered == false else { return }
                        self.operation?.delivered = true
                        self.installStatus = "IPA delivered. Installing… accept the iOS prompt if shown."
                        if let recordID = self.operation?.recordID {
                            NotificationCenter.default.post(name: .forgeInstallState, object: nil,
                                                            userInfo: ["recordID": recordID, "state": SigningRecord.InstallState.delivered.rawValue])
                        }
                        InstallKeepAlive.shared.stop()
                        self.onDelivered?()
                    }
                }

                let health = URL(string: "\(server.installBaseURL)/health")!
                let (_, healthResp) = try await URLSession.shared.data(from: health)
                guard self.operation?.id == id,
                      (healthResp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "forgesign.install", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Local install server failed self-check."])
                }

                guard let plistURL = URL(string: server.remoteManifestURL) else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
                }
                let (plistData, plistResp) = try await URLSession.shared.data(from: plistURL)
                guard self.operation?.id == id,
                      (plistResp as? HTTPURLResponse)?.statusCode == 200,
                      NetworkPolicy.manifestIsValid(plistData,
                                                    packageURL: server.payloadURL,
                                                    bundleID: bundleId,
                                                    version: version) else {
                    throw NSError(domain: "forgesign.install", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Remote manifest server unavailable. Check network and retry."])
                }

                guard let itmsURL = URL(string: server.itmsServicesURL) else {
                    throw NSError(domain: "forgesign.install", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
                }
                guard self.operation?.id == id else { return }
                self.installStatus = "Triggering installer…"
                UIApplication.shared.open(itmsURL) { [weak self] opened in
                    Task { @MainActor in
                        guard let self, self.operation?.id == id else { return }
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
                try await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                self.finish(id: id, status: nil)
            } catch is CancellationError {
                self.finish(id: id, status: "Install cancelled.")
            } catch {
                self.finish(id: id, status: "Install failed: \(error.localizedDescription)")
            }
        }
        operation?.task = task
    }

    func cancelInstall(markFailed: Bool = false) {
        guard let id = operation?.id else { return }
        operation?.task?.cancel()
        let message = markFailed ? "Install failed: Background execution ended." : "Install cancelled."
        finish(id: id, status: message)
    }

    private func finish(id: UUID, status: String?) {
        guard let current = operation, current.id == id else { return }
        current.server?.stop()
        InstallKeepAlive.shared.stop()
        endObservation()
        if current.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(current.backgroundTask)
        }
        if let status { installStatus = status }
        if let recordID = current.recordID, status?.hasPrefix("Install failed") == true {
            NotificationCenter.default.post(name: .forgeInstallState, object: nil,
                                            userInfo: ["recordID": recordID, "state": SigningRecord.InstallState.failed.rawValue])
        }
        installServer = nil
        operation = nil
        onDelivered = nil
    }

    func openInstallPage() {
        guard let server = installServer else { return }
        guard let page = URL(string: "\(server.installBaseURL)/install") else { return }
        installStatus = "Opening install page in Safari…"
        UIApplication.shared.open(page)
    }
}

extension Notification.Name {
    static let forgeInstallStarted = Notification.Name("ForgeSign.installStarted")
    static let forgeInstallState = Notification.Name("ForgeSign.installState")
}
