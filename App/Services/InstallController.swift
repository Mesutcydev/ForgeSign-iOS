import UIKit

/// Owns the semi-local OTA install flow and one active operation at a time.
@MainActor
final class InstallController: ObservableObject {
    @Published var installServer: LocalInstallServer?
    @Published var installStatus = ""

    /// Structured milestones for `InstallCoordinator`. Additive: the legacy
    /// `installStatus` strings remain the source of truth for the existing UI,
    /// and the OTA transport keeps behaving exactly as before.
    var onProgress: ((InstallationProgress) -> Void)?

    private func emit(_ phase: InstallationPhase, _ message: String, fraction: Double? = nil) {
        onProgress?(InstallationProgress(phase: phase, message: message, fraction: fraction))
    }

    private struct Operation {
        let id: UUID
        let recordID: UUID?
        var server: LocalInstallServer?
        var task: Task<Void, Never>?
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        var transferFraction: Double = 0
        var delivered = false
    }

    private var operation: Operation?
    private var lifecycleObservers: [any NSObjectProtocol] = []

    private func observeForeground(for id: UUID) {
        endObservation()
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let operation = self.operation,
                      operation.id == id, !operation.delivered else { return }
                // Returning before iOS asked for any bytes means the install is
                // still waiting on the prompt (or was abandoned): silence the
                // keep-alive. Once the download has started it must keep
                // running, or leaving again lets the background task expire
                // and cancel the transfer mid-way.
                if operation.transferFraction == 0 {
                    InstallKeepAlive.shared.stop()
                }
                if self.installStatus.hasPrefix("Waiting for iOS") {
                    self.installStatus = "Waiting for iOS to request the IPA. If no install prompt appeared, try “Retry via Safari”."
                    self.emit(.awaitingSystem, self.installStatus)
                }
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let operation = self.operation,
                      operation.id == id, !operation.delivered else { return }
                // The server is still waiting for iOS: keep the process alive.
                InstallKeepAlive.shared.start()
            }
        })
    }

    private func endObservation() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    func install(ipa: URL, bundleId: String, version: String, recordID: UUID? = nil) {
        cancelInstall(markFailed: false)
        let id = UUID()
        var newOperation = Operation(id: id, recordID: recordID)
        installStatus = "Starting install server…"
        emit(.preparingPackage, installStatus)
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
            var failureContext = "starting the install service"
            do {
                try Task.checkCancellation()
                let server = LocalInstallServer()
                _ = try await server.start(ipa: ipa, bundleId: bundleId, bundleVersion: version,
                                           title: ipa.deletingPathExtension().lastPathComponent)
                // Cancelled while the server was starting: nothing else owns
                // it yet, so stop it here or its listener and port leak.
                guard !Task.isCancelled, self.operation?.id == id else {
                    server.stop()
                    return
                }
                self.operation?.server = server
                self.installServer = server
                self.emit(.connecting, "Local install server ready.")
                server.onIPAProgress = { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.operation?.id == id, self.operation?.delivered == false else { return }
                        guard fraction > (self.operation?.transferFraction ?? 0) else { return }
                        self.operation?.transferFraction = fraction
                        self.installStatus = "Sending IPA to iOS…"
                        self.emit(.transferring(fraction), self.installStatus, fraction: fraction)
                    }
                }
                server.onIPADelivered = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.operation?.id == id, self.operation?.delivered == false else { return }
                        self.operation?.delivered = true
                        self.installStatus = "IPA transferred to iOS. Check the Home Screen for install progress."
                        self.emit(.delivered, self.installStatus)
                        if let recordID = self.operation?.recordID {
                            NotificationCenter.default.post(name: .forgeInstallState, object: nil,
                                                            userInfo: ["recordID": recordID, "state": SigningRecord.InstallState.delivered.rawValue])
                        }
                        self.finish(id: id, status: nil)
                    }
                }

                let health = URL(string: "\(server.installBaseURL)/health")!
                failureContext = "checking the local handoff"
                var healthRequest = URLRequest(url: health)
                healthRequest.timeoutInterval = 10
                let (_, healthResp) = try await URLSession.shared.data(for: healthRequest)
                guard self.operation?.id == id,
                      (healthResp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "forgesign.install", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Local install server failed self-check."])
                }

                guard let plistURL = URL(string: server.remoteManifestURL) else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
                }
                failureContext = "fetching the install manifest"
                let manifestSession = NetworkPolicy.makeValidatedSession()
                defer { manifestSession.invalidateAndCancel() }
                let (plistData, plistResp) = try await manifestSession.data(from: plistURL)
                guard self.operation?.id == id,
                      (plistResp as? HTTPURLResponse)?.statusCode == 200,
                      NetworkPolicy.manifestIsValid(plistData,
                                                    packageURL: server.payloadURL,
                                                    bundleID: bundleId,
                                                    version: version) else {
                    throw NSError(domain: "forgesign.install", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Remote manifest server unavailable. Check network and retry."])
                }

                failureContext = "opening the iOS installer"
                guard let itmsURL = URL(string: server.itmsServicesURL) else {
                    throw NSError(domain: "forgesign.install", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
                }
                guard self.operation?.id == id else { return }
                self.installStatus = "Opening the iOS installer…"
                self.emit(.awaitingSystem, self.installStatus)
                UIApplication.shared.open(itmsURL) { [weak self] opened in
                    Task { @MainActor in
                        guard let self, self.operation?.id == id else { return }
                        if opened {
                            self.installStatus = "Waiting for iOS to request the IPA. Accept the install prompt if it appears."
                            self.emit(.awaitingSystem, self.installStatus)
                        } else {
                            self.openInstallPage()
                        }
                    }
                }
                try await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                self.finish(id: id, status: "Install failed: iOS did not download the IPA. Try again or use the Safari install page.")
            } catch is CancellationError {
                self.finish(id: id, status: "Install cancelled.")
            } catch {
                self.finish(id: id, status: "Install failed while \(failureContext): \(error.localizedDescription)")
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

    /// Tears down an in-flight install without surfacing terminal status.
    /// Used when a new signing run replaces the previous install attempt:
    /// the old operation ends silently instead of resurrecting its status
    /// (or marking a Library record failed) under the new run.
    func abortQuietly() {
        guard let id = operation?.id else {
            installStatus = ""
            return
        }
        operation?.task?.cancel()
        finish(id: id, status: nil)
        installStatus = ""
    }

    private func finish(id: UUID, status: String?) {
        guard let current = operation, current.id == id else { return }
        current.task?.cancel()
        current.server?.stop()
        InstallKeepAlive.shared.stop()
        endObservation()
        if current.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(current.backgroundTask)
        }
        if let status {
            installStatus = status
            if status.hasPrefix("Install failed") {
                onProgress?(InstallationProgress(phase: .failed(status), message: status))
            } else if status.hasPrefix("Install cancelled") {
                onProgress?(InstallationProgress(phase: .cancelled, message: status))
            }
        }
        if let recordID = current.recordID, !current.delivered {
            let state: SigningRecord.InstallState = status?.hasPrefix("Install failed") == true ? .failed : .signed
            NotificationCenter.default.post(name: .forgeInstallState, object: nil,
                                            userInfo: ["recordID": recordID, "state": state.rawValue])
        }
        installServer = nil
        operation = nil
    }

    func openInstallPage() {
        guard let server = installServer else { return }
        guard let page = URL(string: "\(server.installBaseURL)/install") else { return }
        installStatus = "Opening the Safari install page. Tap Install there to continue."
        emit(.awaitingSystem, installStatus)
        let id = operation?.id
        UIApplication.shared.open(page) { [weak self] opened in
            Task { @MainActor in
                guard let self, let id, self.operation?.id == id, !opened else { return }
                self.finish(id: id, status: "Install failed: Safari could not open the install page.")
            }
        }
    }
}

extension Notification.Name {
    static let forgeInstallState = Notification.Name("ForgeSign.installState")
}
