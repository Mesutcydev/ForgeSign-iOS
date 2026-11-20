import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var signer: SigningService
    @StateObject private var altServer = AltServerClient()
    @StateObject private var altProvisioner = AltServerProvisioningService()

    @EnvironmentObject private var certStore: CertificateStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var install: InstallController
    @EnvironmentObject private var installCoordinator: InstallCoordinator
    @EnvironmentObject private var repoStore: RepositoryStore
    @EnvironmentObject private var imports: ImportRouter
    @EnvironmentObject private var refreshSources: RefreshSourceStore
    @Environment(\.forgeTheme) private var T

    @State private var ipaURL: URL?
    @State private var password = ""
    @State private var bundleId = ""
    /// Bundle ID that Apple Account provisioning filled in, so the next IPA
    /// does not inherit it and install over the previous app.
    @State private var autoBundleID: String?
    @State private var removeExtensions = false
    @State private var enableDocuments = false
    /// Set by "Sign Without App Groups": the profile may grant no App Groups.
    @State private var allowMissingAppGroups = false
    /// Set by "Sign Without Watch App": sign the app alone, dropping its Watch app.
    @State private var removeWatchApp = false
    @State private var showSigningLog = false
    /// Set by the extensions button, so the removal lasts for that one sign attempt (audit U3).
    @State private var removeExtensionsByConsent = false
    @State private var pendingImportError: String?
    /// Off by default so existing signing is unchanged. On = AltStore's rule:
    /// only the profile entitlements the app itself declares.
    @AppStorage("matchAppEntitlements") private var matchAppEntitlements = false
    @State private var dylibURL: URL?
    @State private var injectIntoExtensions = false
    @State private var preflightState: IPAPreflightState = .idle
    @State private var provisioningAudit: ProvisioningAudit?
    @State private var signedIPA: URL?
    @State private var signedBundleId = ""
    @State private var signedVersion = "1.1"
    @State private var lastRecordID: UUID?
    @State private var showIPAImporter = false
    @State private var showProfileSheet = false
    @State private var showCertSheet = false
    @State private var showDylibImporter = false
    @State private var showShare = false
    @State private var importError: String?
    @State private var isImporting = false
    @State private var provisioningWarning: String?
    @AppStorage("automaticProvisioningEnabled") private var automaticProvisioningEnabled = false
    /// Kept in the Keychain (AppleAccountVault), not in preferences (audit N7).
    @State private var altServerAppleID = ""
    @AppStorage("altServerDeviceIdentifier") private var altServerDeviceIdentifier = ProvisioningAuditService.currentDeviceIdentifier ?? ""
    @AppStorage("anisetteServerURL") private var anisetteServerURL = ""
    @AppStorage("anisetteMode") private var anisetteModeRaw = ""
    @AppStorage("anisetteRemoteServerAddress") private var remoteAnisetteServerAddress = ""
    /// Keeps a copy of the imported package so a later refresh can re-sign the
    /// same input. Off by default: it costs disk.
    @AppStorage("retainRefreshSources") private var retainRefreshSources = false
    @State private var altServerApplePassword = ""
    @State private var signNotice: String?

    private var anisetteMode: AnisetteMode {
        AnisettePreference.resolvedMode(storedMode: anisetteModeRaw,
                                        legacyCustomURLText: anisetteServerURL)
    }

    private var anisettePlan: AnisettePreference.Plan {
        AnisettePreference.plan(mode: anisetteMode,
                                remoteServerAddress: remoteAnisetteServerAddress.isEmpty ? nil : remoteAnisetteServerAddress,
                                customURLText: anisetteServerURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header

                        inputSection
                            .disabled(!signer.canAcceptInput)
                        if ipaURL != nil {
                            IPAPreflightCard(state: preflightState,
                                             certificate: certStore.selected,
                                             profile: profileStore.selected,
                                             audit: provisioningAudit)
                        }
                        if signer.isStaging {
                            FileCopyProgressView(title: "Importing file…", progress: signer.copyProgress,
                                                 cancel: signer.cancelInputCopy)
                        }
                        if refreshSources.isRetaining {
                            FileCopyProgressView(title: "Keeping original for refresh…", progress: refreshSources.copyProgress,
                                                 cancel: refreshSources.cancelRetention)
                        }
                        optionsSection
                            .disabled(signer.isBusy)
                        AutomaticProvisioningSection(
                            isEnabled: $automaticProvisioningEnabled,
                            appleID: $altServerAppleID,
                            applePassword: $altServerApplePassword,
                            deviceIdentifier: $altServerDeviceIdentifier,
                            anisetteModeRaw: $anisetteModeRaw,
                            remoteServerAddress: $remoteAnisetteServerAddress,
                            customAnisetteURL: $anisetteServerURL,
                            altServer: altServer,
                            provisioner: altProvisioner
                        )
                        .disabled(signer.isBusy)
                        DylibInjectionSection(dylibURL: $dylibURL,
                                              injectIntoExtensions: $injectIntoExtensions,
                                              chooseDylib: { showDylibImporter = true },
                                              removeDylib: {
                                                  dylibURL = nil
                                                  injectIntoExtensions = false
                                              })
                        .disabled(!signer.canAcceptInput)
                        signButton

                        if let hint = signReadinessHint {
                            readinessHint(hint)
                        }

                        if let signNotice {
                            warningCard(signNotice)
                            if canSignWithoutExtensions {
                                GlassSecondaryButton(label: "Sign Without App Extensions",
                                                     systemImage: "puzzlepiece.extension") {
                                    removeExtensions = true
                                    removeExtensionsByConsent = true
                                    sign(allowAutomaticProvisioning: false)
                                }
                                .padding(.horizontal, T.pad)
                                .padding(.top, 12)
                            } else if canSignWithoutAppGroups {
                                GlassSecondaryButton(label: "Sign Without App Groups",
                                                     systemImage: "lock.open") {
                                    allowMissingAppGroups = true
                                    sign(allowAutomaticProvisioning: false)
                                }
                                .padding(.horizontal, T.pad)
                                .padding(.top, 12)
                            } else if canSignWithoutWatchApp {
                                GlassSecondaryButton(label: "Sign Without Watch App",
                                                     systemImage: "applewatch") {
                                    removeWatchApp = true
                                    sign(allowAutomaticProvisioning: false)
                                }
                                .padding(.horizontal, T.pad)
                                .padding(.top, 12)
                            }
                            logButton
                        }

                        if let provisioningWarning, signer.phase != .provisioning {
                            warningCard(provisioningWarning)
                            logButton
                        }

                        if case .failed(let message) = signer.phase {
                            errorCard(message)
                            logButton
                        }

                        if let signedIPA {
                            resultSection(signedIPA)
                        }
                    }
                    .padding(.bottom, 40)
                    .forgeReadableWidth()
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .background { auditObservers }
                .sheet(isPresented: $showIPAImporter, onDismiss: presentPendingImportError) {
                    ForgeDocumentPicker(isPresented: $showIPAImporter) {
                        guard ["ipa", "zip"].contains($0.pathExtension.lowercased()) else {
                            pendingImportError = "Choose an IPA or ZIP archive."
                            return
                        }
                        stageIPA($0)
                    }
                }
                .sheet(isPresented: $showDylibImporter, onDismiss: presentPendingImportError) {
                    ForgeDocumentPicker(isPresented: $showDylibImporter) {
                        guard $0.pathExtension.lowercased() == "dylib" else {
                            pendingImportError = "Choose a .dylib file."
                            return
                        }
                        stageDylib($0)
                    }
                }
                .alert("Import failed", isPresented: importErrorShown) {
                    Button("OK", role: .cancel) { importError = nil }
                } message: {
                    Text(importMessage)
                }
                .alert("Two-Factor Authentication", isPresented: $altProvisioner.isRequestingVerificationCode) {
                    TextField("Six-digit code", text: $altProvisioner.verificationCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("Cancel", role: .cancel) { altProvisioner.cancelVerification() }
                    Button("Continue") { altProvisioner.submitVerificationCode() }
                } message: {
                    Text(verificationMessage)
                }
                .sheet(isPresented: $showProfileSheet) {
                    ProfilesSheet()
                }
                .sheet(isPresented: $showCertSheet) {
                    CertificatesSheet()
                }
                .sheet(isPresented: $showSigningLog) {
                    SigningLogView()
                }
                .sheet(isPresented: $showShare) {
                    if let signedIPA { ShareSheet(items: [signedIPA]) }
                }
                .onAppear {
                    processPendingImports()
                    altServerAppleID = AppleAccountVault.load() ?? AppleAccountVault.migrateLegacyPreference() ?? altServerAppleID
                }
                .onChange(of: repoStore.pendingIPA) { _ in processPendingImports() }
                .onChange(of: imports.pending) { _ in processPendingImports() }
                .onChange(of: isImporting) { _ in processPendingImports() }
                .onChange(of: signer.activeInputChecks) { _ in processPendingImports() }
                .onChange(of: signer.phase) { _ in
                    if case .signing = signer.phase { signNotice = nil }
                    if !signer.isBusy { processPendingImports() }
                }
                .onChange(of: signer.stagingResetID) { _ in
                    ipaURL = nil
                    dylibURL = nil
                    preflightState = .idle
                    provisioningAudit = nil
                    signedIPA = nil
                    signer.phase = .idle
                }
                .onChange(of: history.records) { _ in
                    if let signedIPA, !FileManager.default.fileExists(atPath: signedIPA.path) {
                        self.signedIPA = nil
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: T.gap) {
            ForgeGlassLogoView(size: 60)

            Text("ForgeSign")
                .font(T.display(30))
                .foregroundColor(T.ink)

            VStack(spacing: 3) {
                MonoText(text: "ON-DEVICE IPA SIGNER", size: 10, weight: .semibold, color: T.ink3)
                MonoText(text: "by Mesutcydev", size: 9, color: T.ink4)
            }
        }
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    // MARK: - Input

    private var inputSection: some View {
        GlassSection("Input") {
            GlassFileRow(icon: "doc.zipper", label: "IPA", file: ipaURL) { showIPAImporter = true }
            GlassRowDivider()
            certificateRow
            GlassRowDivider()
            profileRow
            GlassRowDivider()
            if let cert = certStore.selected, certStore.savedPassword(for: cert) != nil {
                GlassRow(label: "P12 password") {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(T.accent2)
                        GlassStatusPill(text: "Keychain", color: T.accent)
                    }
                }
            } else {
                GlassInputRow(icon: "lock.fill", label: "P12 password", placeholder: "If set", text: $password, isSecure: true)
            }
        }
    }

    private var certificateRow: some View {
        let certificate = certStore.selected
        let expiry = P12Inspector.expiry(certificate?.notAfter)
        return SigningAssetRow(
            icon: "key.fill", label: "Certificate (.p12)", value: certificate?.displayName,
            status: certificate == nil ? nil : expiry.text, statusColor: expiry.tone.color(in: T)
        ) { showCertSheet = true }
    }

    private var profileRow: some View {
        let profile = profileStore.selected
        let expiry = P12Inspector.expiry(profile?.notAfter)
        return SigningAssetRow(
            icon: "checkmark.seal.fill", label: "Provisioning profile", value: profile?.displayName,
            status: profile == nil ? nil : expiry.text, statusColor: expiry.tone.color(in: T)
        ) { showProfileSheet = true }
    }

    // MARK: - Options

    private var optionsSection: some View {
        GlassSection("Options") {
            GlassInputRow(icon: "curlybraces", label: "New bundle ID", placeholder: "Optional", text: $bundleId)
            GlassRowDivider()
            GlassToggleRow(label: "Remove app extensions", isOn: $removeExtensions)
            GlassRowDivider()
            GlassToggleRow(label: "Enable Files import / sharing", isOn: $enableDocuments)
            GlassRowDivider()
            GlassToggleRow(label: "Use app's own entitlements (AltStore style)", isOn: $matchAppEntitlements)
        }
    }

    // MARK: - Sign CTA

    private var signButton: some View {
        let signing = signer.phase == .signing
        let provisioning = signer.phase == .provisioning
        let busy = signing || provisioning
        return Button {
            sign()
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .tint(T.isDark ? .white : T.ink)
                    Text(provisioning ? "Provisioning…" : "Signing…")
                        .font(T.sans(15, .semibold))
                } else {
                    Image(systemName: "signature")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sign IPA").font(T.sans(15, .semibold))
                }
            }
            .foregroundColor(T.isDark ? .white : T.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity)
            .glassSurface(.button)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule2, lineWidth: AppStroke.hairline)
            }
            .opacity(!canSign || busy ? 0.45 : 1)
        }
        .buttonStyle(GlassTactileButtonStyle())
        .disabled(!canSign || busy)
        .padding(.horizontal, T.pad)
        .padding(.top, 28)
    }

    // MARK: - Error

    private func warningCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(T.warn)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(T.warn)
                .padding(.top, 1)
            Text(message)
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fGlass(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.warn.opacity(0.35), lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(T.bad)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(T.bad)
                .padding(.top, 1)
            Text(message)
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fGlass(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.bad.opacity(0.35), lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    // MARK: - Result

    private func resultSection(_ signedIPA: URL) -> some View {
        GlassSection("Result") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    GlassStatusPill(text: "Signed", color: T.good)
                    Text(signedIPA.lastPathComponent)
                        .font(T.mono(12))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                GlassRowDivider()

                GlassRow(label: "Bundle ID") {
                    Text(signedBundleId)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !installStatusText.isEmpty {
                    GlassRowDivider()
                    HStack(alignment: .top, spacing: 8) {
                        if installCoordinator.phase.isActive {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Installation in progress")
                        } else {
                            Image(systemName: "iphone")
                                .font(.system(size: 11))
                                .foregroundColor(T.accent2)
                                .padding(.top, 1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if let phase = installPhaseText {
                                Text(phase)
                                    .font(T.mono(10, .semibold))
                                    .foregroundColor(installPhaseColor)
                            }
                            Text(installStatusText)
                                .font(T.mono(10))
                                .foregroundColor(T.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }

                GlassRowDivider()

                VStack(spacing: T.gap) {
                    GlassPrimaryButton(label: installButtonLabel,
                                       systemImage: "arrow.down.app",
                                       action: { startInstall() },
                                       disabled: installCoordinator.isInstalling)
                    if installCoordinator.isInstalling {
                        GlassSecondaryButton(label: "Cancel Install", systemImage: "xmark.circle") {
                            installCoordinator.cancel()
                        }
                    }
                    if installCoordinator.lastError != nil, installCoordinator.canRetry, !installCoordinator.isInstalling {
                        GlassSecondaryButton(label: "Try Again", systemImage: "arrow.clockwise") {
                            installCoordinator.retry()
                        }
                    }
                    if install.installServer != nil {
                        GlassSecondaryButton(label: "Retry via Safari", systemImage: "safari") {
                            install.openInstallPage()
                        }
                    }
                    GlassSecondaryButton(label: "Share / Save signed IPA", systemImage: "square.and.arrow.up") {
                        showShare = true
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Logic

    private func processPendingImports() {
        // Keep imports queued while the native engine or inspection owns its
        // inputs. Also handles an Open In request received before this tab mounts.
        guard signer.canAcceptInput, !isImporting else { return }
        if let request = imports.consume() {
            switch request {
            case .ipa(let url): stageIPA(url)
            case .dylib(let url): stageDylib(url)
            case .refresh(let url, let bundleID, let name):
                stageIPA(url, as: name, bundleID: bundleID)
            }
        } else if let pending = repoStore.pendingIPA {
            repoStore.pendingIPA = nil
            stageIPA(pending)
        }
    }

    /// - Parameters:
    ///   - name: file name to stage under (a refresh's kept original is stored
    ///     under an internal name; this keeps the output named after the app).
    ///   - bundleID: bundle ID to sign with (a refresh reuses the installed one).
    private func stageIPA(_ source: URL, as name: String? = nil, bundleID: String? = nil) {
        guard signer.canAcceptInput, !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let localURL = try await signer.stage(source, as: name)
                ipaURL = localURL
                if let autoBundleID {
                    if bundleId == autoBundleID { bundleId = "" }
                    self.autoBundleID = nil
                }
                if let bundleID { bundleId = bundleID }
                provisioningAudit = nil
                allowMissingAppGroups = false
                // A new input starts with no result or error from the previous one (audit U1).
                signedIPA = nil
                signer.phase = .idle
                signer.pruneStagedArchives(keeping: localURL)
                preflightState = .inspecting
                signer.beginInputCheck()
                let temporaryDirectory = signer.tempDir
                Task.detached(priority: .utility) {
                    let result = IPAPreflightService.inspect(ipa: localURL, temporaryDirectory: temporaryDirectory)
                    await MainActor.run {
                        signer.endInputCheck()
                        guard ipaURL == localURL else { return }
                        switch result {
                        case .success(let inspection):
                            preflightState = .ready(inspection)
                            refreshProvisioningAudit(inspection)
                        case .failure(let error):
                            preflightState = .failed(error.localizedDescription)
                            provisioningAudit = nil
                        }
                    }
                }
            } catch is CancellationError {
                // Keep the previous input and its preflight result.
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func stageDylib(_ source: URL) {
        guard signer.canAcceptInput, !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                dylibURL = try await signer.stage(source)
                importError = nil
            } catch is CancellationError {
                // Keep the previous optional injection.
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private var importMessage: String { importError ?? "" }

    private var verificationMessage: String {
        altProvisioner.verificationNotice ?? "Enter the verification code Apple sent to your trusted device."
    }

    /// Presents the import alert while an error is set.
    private var importErrorShown: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    /// The inputs that change the provisioning audit. Kept out of the main body so the
    /// body stays small enough for the compiler (audit U4).
    private var auditObservers: some View {
        Color.clear
            .frame(width: 0, height: 0)
                .onChange(of: profileStore.profiles) { _ in refreshProvisioningAudit() }
                .onChange(of: profileStore.isRefreshingMetadata) { _ in refreshProvisioningAudit() }
                .onChange(of: profileStore.selectedID) { _ in refreshProvisioningAudit() }
                .onChange(of: certStore.selectedID) { _ in refreshProvisioningAudit() }
                .onChange(of: bundleId) { _ in refreshProvisioningAudit() }
                .onChange(of: removeExtensions) { _ in refreshProvisioningAudit() }
                .onChange(of: allowMissingAppGroups) { _ in refreshProvisioningAudit() }
                .onChange(of: removeWatchApp) { _ in refreshProvisioningAudit() }
                .onChange(of: altServerAppleID) { storeAppleID($0) }
                .onChange(of: altServerApplePassword) { _ in refreshProvisioningAudit() }
                .onChange(of: anisetteServerURL) { _ in refreshProvisioningAudit() }
                .onChange(of: automaticProvisioningEnabled) { _ in refreshProvisioningAudit() }
                .onChange(of: altServerDeviceIdentifier) { _ in refreshProvisioningAudit() }
                .onChange(of: anisetteModeRaw) { _ in refreshProvisioningAudit() }
                .onChange(of: remoteAnisetteServerAddress) { _ in refreshProvisioningAudit() }
    }

    /// Keeps the Apple ID in the Keychain and re-checks the audit it feeds (audit U4).
    private func storeAppleID(_ value: String) {
        AppleAccountVault.store(value)
        refreshProvisioningAudit()
    }

    /// Shows an import error once its picker has closed, so the alert is not
    /// presented over the sheet that is still dismissing (audit U12).
    private func presentPendingImportError() {
        if let message = pendingImportError {
            importError = message
            pendingImportError = nil
        }
    }

    private var effectivePassword: String? {
        if let cert = certStore.selected, let saved = certStore.savedPassword(for: cert) {
            return saved
        }
        // An empty password is valid for an unprotected P12. The signing
        // engine still validates the certificate before using it.
        return password
    }

    private var isAppleAccountReady: Bool {
        !altServerAppleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !altServerApplePassword.isEmpty
            && !altServerDeviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && altServer.hasAnisetteSource(plan: anisettePlan)
    }

    /// Explains, under the Sign button, exactly what is still missing. The
    /// button used to go quiet with no explanation, which read as “nothing happens”.
    private var signReadinessHint: String? {
        if signer.phase == .signing { return nil }
        if signer.phase == .provisioning { return altProvisioner.statusText }
        if ipaURL == nil { return "Choose an IPA to begin." }
        if let blocker = preflightState.signingBlocker { return blocker }
        if profileStore.isRefreshingMetadata { return "Reading provisioning profiles…" }

        if automaticProvisioningEnabled {
            if !isAppleAccountReady {
                if canSignManually {
                    return "Apple Account details are incomplete, so ForgeSign will sign with the selected certificate and profile. The Preflight card lists anything that blocks this IPA."
                }
                return "Add a certificate and profile, or enter your Apple Account details plus an anisette source."
            }
            if case .ready = preflightState { return nil }
            return "Inspecting the IPA…"
        }

        if !canSignManually { return "Add a certificate (.p12 with its password) and a provisioning profile." }
        return nil
    }

    private var canSign: Bool {
        guard ipaURL != nil else { return false }
        guard signer.canAcceptInput, !isImporting, preflightState.signingBlocker == nil else { return false }
        guard !profileStore.isRefreshingMetadata else { return false }
        guard automaticProvisioningEnabled else { return canSignManually }
        let inspectionReady: Bool
        if case .ready = preflightState { inspectionReady = true } else { inspectionReady = false }
        return canSignManually || (isAppleAccountReady && inspectionReady)
    }

    private func refreshProvisioningAudit(_ inspection: IPAPreflight? = nil) {
        guard !profileStore.isRefreshingMetadata else {
            provisioningAudit = nil
            return
        }
        let resolvedInspection: IPAPreflight
        if let inspection {
            resolvedInspection = inspection
        } else if case .ready(let ready) = preflightState {
            resolvedInspection = ready
        } else {
            provisioningAudit = nil
            return
        }
        let automaticPath = automaticProvisioningEnabled && isAppleAccountReady
        provisioningAudit = ProvisioningAuditService.makeAudit(
            inspection: resolvedInspection,
            profiles: profileStore.profiles,
            preferredProfileID: profileStore.selectedID,
            certificate: certStore.selected,
            requestedBundleID: bundleId,
            removeExtensions: removeExtensions,
            ignoreAppGroups: allowMissingAppGroups,
            removeWatchApp: removeWatchApp,
            deviceIdentifier: automaticPath
                ? altServerDeviceIdentifier
                : ProvisioningAuditService.currentDeviceIdentifier
        )
    }

    /// Helper line under the Sign button — says what is missing instead of
    /// leaving the user with a disabled button and no explanation.
    private func readinessHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(T.ink3)
                .padding(.top, 1)
            Text(text)
                .font(T.mono(10))
                .foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 10)
    }

    private var canSignWithoutExtensions: Bool {
        !removeExtensions && provisioningAudit?.onlyExtensionsBlocked == true
    }

    private var canSignWithoutAppGroups: Bool {
        !allowMissingAppGroups && provisioningAudit?.onlyAppGroupsBlocked == true
    }

    private var canSignWithoutWatchApp: Bool {
        !removeWatchApp && provisioningAudit?.onlyWatchAppBlocked == true
    }

    /// Opens the signing log beside any failure or warning.
    private var logButton: some View {
        GlassSecondaryButton(label: "View Signing Log", systemImage: "doc.plaintext") {
            showSigningLog = true
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 12)
    }

    private var canSignManually: Bool {
        certStore.selected != nil && profileStore.selected != nil && effectivePassword != nil
    }

    private func sign(allowAutomaticProvisioning: Bool = true) {
        guard !signer.isBusy, !isImporting else { return }
        // "Sign Without App Groups" consents to one sign attempt, not the IPA.
        defer {
            allowMissingAppGroups = false
            removeWatchApp = false
            // The extensions removal from the button lasts for this attempt only (audit U3).
            if removeExtensionsByConsent {
                removeExtensions = false
                removeExtensionsByConsent = false
            }
        }
        signNotice = nil
        guard let ipa = ipaURL else {
            ForgeLog.event("Sign stopped: no IPA is chosen.")
            signNotice = "Choose an IPA first — there is nothing to sign yet."
            return
        }
        if let blocker = preflightState.signingBlocker {
            ForgeLog.event("Blocked before signing: \(blocker)")
            signNotice = blocker
            return
        }

        if automaticProvisioningEnabled,
           allowAutomaticProvisioning,
           case .ready(let inspection) = preflightState {
            let audit = ProvisioningAuditService.makeAudit(
                inspection: inspection,
                profiles: profileStore.profiles,
                preferredProfileID: profileStore.selectedID,
                certificate: certStore.selected,
                requestedBundleID: bundleId,
                removeExtensions: removeExtensions,
                ignoreAppGroups: allowMissingAppGroups,
                removeWatchApp: removeWatchApp,
                deviceIdentifier: altServerDeviceIdentifier
            )
            provisioningAudit = audit
            // Apple is only contacted when the imported certificate and
            // profiles cannot cover this IPA; a working manual setup never
            // waits on (or fails with) Apple's sign-in service. A custom
            // bundle ID that only the selected-profile fallback covers gets
            // a matching profile from Apple instead.
            if isAppleAccountReady &&
                (!canSignManually || !audit.isReady || audit.usesSelectedProfileFallback) {
                obtainMissingProfiles(inspection: inspection,
                                      audit: audit,
                                      certificate: certStore.selected)
                return
            }
        }

        guard let cert = certStore.selected,
              let pw = effectivePassword,
              let profile = profileStore.selected else {
            ForgeLog.event("Sign stopped: no certificate or profile is selected.")
            signNotice = allowAutomaticProvisioning
                ? "Signing needs a certificate (.p12 with its password) and a provisioning profile. Add them under Input, or enter your Apple Account details under Provisioning so ForgeSign can create them."
                : "ForgeSign could not select the certificate or profile it just created. Tap Sign again, or import a certificate and profile manually."
            return
        }
        let p12 = certStore.fileURL(for: cert)
        guard case .ready(let inspection) = preflightState else { return }
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspection,
            profiles: profileStore.profiles,
            preferredProfileID: profile.id,
            certificate: cert,
            requestedBundleID: bundleId,
            removeExtensions: removeExtensions,
            ignoreAppGroups: allowMissingAppGroups,
            removeWatchApp: removeWatchApp,
            deviceIdentifier: automaticProvisioningEnabled && isAppleAccountReady
                ? altServerDeviceIdentifier
                : ProvisioningAuditService.currentDeviceIdentifier
        )
        provisioningAudit = audit
        if let blocker = audit.rows.first(where: { $0.state.isBlocking }) {
            let advice: String
            if canSignWithoutExtensions {
                advice = "Import a matching profile, or sign without app extensions. Extension features, such as widgets or sharing, will be unavailable."
            } else if audit.onlyAppGroupsBlocked {
                advice = "The \(blocker.kind.displayName.lowercased()) needs App Groups (\(blocker.requiredAppGroups.joined(separator: ", "))). "
                    + "To sign now, turn them off; the signed app loses access to their shared data. "
                    + "Or import a profile that grants them."
            } else if audit.onlyWatchAppBlocked {
                advice = "To sign now, remove the Watch app. It will not be installed. Or import a profile that covers it."
            } else {
                advice = "Import a matching profile or use Apple Account provisioning."
            }
            signNotice = "\(blocker.kind.displayName) \(blocker.resolvedBundleID): \(blocker.detail) " + advice
            ForgeLog.event("Blocked before signing: \(blocker.kind.displayName) \(blocker.resolvedBundleID): \(blocker.detail)")
            return
        }

        // The audit selects a valid root profile as well as nested profiles.
        // An unrelated selected profile must not be added back to this plan.
        let profileFiles = audit.selectedProfileIDs.compactMap { id in
            profileStore.profiles.first { $0.id == id }
        }
        guard !profileFiles.isEmpty, profileFiles.count == audit.selectedProfileIDs.count else {
            ForgeLog.event("Sign stopped: the matching profiles are no longer available.")
            signNotice = "The matching profiles are no longer available. Choose them again."
            return
        }
        let certCN = cert.commonName
        // The profiles embedded in the result expire when the earliest of the
        // profiles we are about to embed expires. Recorded with the library
        // entry so refresh can tell when the app is due.
        let profileExpiry = profileFiles.compactMap(\.notAfter).min()
        let retainSource = retainRefreshSources

        signer.phase = .signing
        if allowAutomaticProvisioning { provisioningWarning = nil }
        signedIPA = nil
        lastRecordID = nil
        install.abortQuietly()
        installCoordinator.reset()
        InstallKeepAlive.shared.stop()
        let output = history.uniqueOutputURL(for: ipa.lastPathComponent)
        let outName = output.lastPathComponent
        let request = SigningRequest(
            ipa: ipa, p12: p12, password: pw,
            profiles: profileFiles.map { SigningRequest.Profile(url: profileStore.fileURL(for: $0), name: $0.displayName, isAuthentic: $0.profileIsAuthentic) },
            bundleID: bundleId.trimmingCharacters(in: .whitespacesAndNewlines),
            output: output, temporaryDirectory: signer.tempDir,
            removeExtensions: removeExtensions, enableDocuments: enableDocuments,
            matchAppEntitlements: matchAppEntitlements, dylib: dylibURL,
            injectIntoExtensions: injectIntoExtensions,
            removeWatchApp: removeWatchApp
        )
        Task {
            defer { signer.cleanTemp() }
            switch await SigningWorker.run(request) {
            case .failure(let error):
                signer.phase = .failed(error.message)
            case .success(let result):
                provisioningWarning = nil
                let record = history.append(inputName: ipa.lastPathComponent,
                                            outputName: outName, bundleId: result.bundleID,
                                            version: result.version, certificateCN: certCN,
                                            profileExpiresAt: profileExpiry)
                lastRecordID = record.id
                // The result is shown before any retained copy is made, so the screen
                // does not read "Signing…" while the original is copied (audit U15).
                signedIPA = result.url
                signedBundleId = result.bundleID
                signedVersion = result.version
                signer.phase = .done(result.message)
                if retainSource {
                    // Keep the input locked until the original copy finishes.
                    // Only the copy is cancellable; the verified IPA is retained.
                    let kept = await refreshSources.retain(ipa, for: record.id)
                    history.setRefreshSourceName(kept, for: record.id)
                    if let message = refreshSources.retentionError {
                        ForgeLog.event("Original not kept for refresh: \(message)")
                        signNotice = message
                    }
                }
            }
        }
    }

    private func obtainMissingProfiles(inspection: IPAPreflight,
                                       audit: ProvisioningAudit,
                                       certificate: CertificateRecord?) {
        signer.phase = .provisioning
        let request = ProvisioningRequestFactory.request(
            inspection: inspection,
            audit: audit,
            certificate: certificate,
            deviceIdentifier: altServerDeviceIdentifier
        )
        let importedCertificateData = certificate.flatMap { try? Data(contentsOf: certStore.fileURL(for: $0)) }
        let importedCertificatePassword = certificate.flatMap { certStore.savedPassword(for: $0) }
            ?? (password.isEmpty ? nil : password)

        Task {
            do {
                let response = try await altProvisioner.provision(
                    request: request,
                    appleID: altServerAppleID,
                    password: altServerApplePassword,
                    deviceIdentifier: altServerDeviceIdentifier,
                    altServer: altServer,
                    anisettePlan: anisettePlan,
                    importedCertificateData: importedCertificateData,
                    importedCertificatePassword: importedCertificatePassword
                )
                // The password is needed only for this sign-in; it is not kept after success (audit N7).
                altServerApplePassword = ""
                let certificateFilename = "ForgeSign-\(response.teamIdentifier).p12"
                let importedCertificate: CertificateRecord
                switch certStore.importCertificate(data: response.certificateData,
                                                   suggestedFilename: certificateFilename,
                                                   password: response.certificatePassword,
                                                   rememberPassword: true) {
                case .success(let record):
                    importedCertificate = record
                case .failure(let error):
                    throw ProvisioningProviderError.rejected(
                        "The Apple Account certificate could not be saved: \(error.localizedDescription)"
                    )
                }

                var importedProfileIDs: [UUID] = []
                for supplied in response.profiles {
                    guard let data = Data(base64Encoded: supplied.dataBase64) else {
                        throw ProvisioningProviderError.invalidResponse
                    }
                    if let metadata = ProvisioningProfileInspector.inspect(data: data),
                       let uuid = metadata.uuid,
                       let existing = profileStore.profiles.first(where: { $0.profileUUID == uuid }) {
                        importedProfileIDs.append(existing.id)
                        continue
                    }
                    switch profileStore.importProfile(data: data, suggestedFilename: supplied.filename) {
                    case .success(let record):
                        importedProfileIDs.append(record.id)
                    case .failure(let error):
                        throw ProvisioningProviderError.rejected(
                            "Apple returned an unusable profile: \(error.localizedDescription)"
                        )
                    }
                }
                bundleId = response.rootBundleIdentifier
                autoBundleID = response.rootBundleIdentifier
                certStore.select(importedCertificate.id)
                if let rootProfile = profileStore.profiles.first(where: {
                    importedProfileIDs.contains($0.id)
                        && $0.applicationIdentifier?.hasSuffix(".\(response.rootBundleIdentifier)") == true
                }) {
                    profileStore.select(rootProfile.id)
                } else if let first = importedProfileIDs.first {
                    profileStore.select(first)
                }
                refreshProvisioningAudit(inspection)
                signer.phase = .idle
                sign(allowAutomaticProvisioning: false)
            } catch {
                if canSignManually {
                    ForgeLog.event("Apple Account provisioning could not finish: \(error.localizedDescription)")
                    provisioningWarning = "Apple Account provisioning could not finish: \(error.localizedDescription) Checking the imported profiles for manual signing."
                    signer.phase = .idle
                    sign(allowAutomaticProvisioning: false)
                } else {
                    ForgeLog.event("Apple Account provisioning failed: \(error.localizedDescription)")
                    signer.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func startInstall() {
        guard let ipa = signedIPA else { return }
        installCoordinator.install(ipa: ipa,
                                   bundleId: signedBundleId,
                                   version: signedVersion,
                                   recordID: lastRecordID,
                                   displayName: ipa.lastPathComponent)
    }

    /// The coordinator's structured status wins; the controller's legacy string
    /// stays as the detailed line underneath it.
    private var installStatusText: String {
        installCoordinator.statusMessage.isEmpty ? install.installStatus : installCoordinator.statusMessage
    }

    private var installButtonLabel: String {
        guard installCoordinator.isInstalling else { return "Install on Device" }
        switch installCoordinator.phase {
        case .awaitingSystem: return "Waiting for iOS…"
        case .transferring: return "Sending IPA…"
        default: return "Preparing install…"
        }
    }

    private var installPhaseText: String? {
        switch installCoordinator.phase {
        case .idle: return nil
        default: return installCoordinator.phase.label.uppercased()
        }
    }

    private var installPhaseColor: Color {
        switch installCoordinator.phase {
        case .failed: return T.bad
        case .cancelled: return T.ink3
        case .completed, .delivered: return T.good
        default: return T.accent2
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
