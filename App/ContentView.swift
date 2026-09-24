import SwiftUI

struct ContentView: View {
    @StateObject private var signer = SigningService()
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
    @State private var removeExtensions = false
    @State private var enableDocuments = false
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
    @State private var provisioningWarning: String?
    @AppStorage("automaticProvisioningEnabled") private var automaticProvisioningEnabled = false
    @AppStorage("altServerAppleID") private var altServerAppleID = ""
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
                        if ipaURL != nil {
                            IPAPreflightCard(state: preflightState,
                                             certificate: certStore.selected,
                                             profile: profileStore.selected,
                                             audit: provisioningAudit,
                                             manualSigningAvailable: canSignManually)
                        }
                        optionsSection
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
                        DylibInjectionSection(dylibURL: $dylibURL,
                                              injectIntoExtensions: $injectIntoExtensions,
                                              chooseDylib: { showDylibImporter = true },
                                              removeDylib: {
                                                  dylibURL = nil
                                                  injectIntoExtensions = false
                                              })
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
                                    sign(allowAutomaticProvisioning: false)
                                }
                                .padding(.horizontal, T.pad)
                                .padding(.top, 12)
                            }
                        }

                        if let provisioningWarning, signer.phase != .provisioning {
                            warningCard(provisioningWarning)
                        }

                        if case .failed(let message) = signer.phase {
                            errorCard(message)
                        }

                        if let signedIPA {
                            resultSection(signedIPA)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showIPAImporter) {
                    ForgeDocumentPicker {
                        guard ["ipa", "zip"].contains($0.pathExtension.lowercased()) else {
                            importError = "Choose an IPA or ZIP archive."
                            Task { @MainActor in showIPAImporter = false }
                            return
                        }
                        stageIPA($0)
                        Task { @MainActor in showIPAImporter = false }
                    }
                }
                .sheet(isPresented: $showDylibImporter) {
                    ForgeDocumentPicker {
                        guard $0.pathExtension.lowercased() == "dylib" else {
                            importError = "Choose a .dylib file."
                            Task { @MainActor in showDylibImporter = false }
                            return
                        }
                        stageDylib($0)
                        Task { @MainActor in showDylibImporter = false }
                    }
                }
                .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("OK", role: .cancel) { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
                .alert("Two-Factor Authentication", isPresented: $altProvisioner.isRequestingVerificationCode) {
                    TextField("Six-digit code", text: $altProvisioner.verificationCode)
                        .keyboardType(.numberPad)
                    Button("Cancel", role: .cancel) { altProvisioner.cancelVerification() }
                    Button("Continue") { altProvisioner.submitVerificationCode() }
                } message: {
                    Text("Enter the verification code Apple sent to your trusted device.")
                }
                .sheet(isPresented: $showProfileSheet) {
                    ProfilesSheet()
                }
                .sheet(isPresented: $showCertSheet) {
                    CertificatesSheet()
                }
                .sheet(isPresented: $showShare) {
                    if let signedIPA { ShareSheet(items: [signedIPA]) }
                }
                .onChange(of: repoStore.pendingIPA) { pending in
                    // A repo download landed — load it as the input to sign.
                    if let pending {
                        stageIPA(pending, fallbackToSource: true)
                        repoStore.pendingIPA = nil
                    }
                }
                .onChange(of: imports.pending) { _ in
                    guard let request = imports.consume() else { return }
                    switch request {
                    case .ipa(let url): stageIPA(url)
                    case .dylib(let url): stageDylib(url)
                    }
                }
                .onChange(of: profileStore.profiles) { _ in refreshProvisioningAudit() }
                .onChange(of: profileStore.isRefreshingMetadata) { _ in refreshProvisioningAudit() }
                .onChange(of: profileStore.selectedID) { _ in refreshProvisioningAudit() }
                .onChange(of: certStore.selectedID) { _ in refreshProvisioningAudit() }
                .onChange(of: bundleId) { _ in refreshProvisioningAudit() }
                .onChange(of: removeExtensions) { _ in refreshProvisioningAudit() }
                .onChange(of: automaticProvisioningEnabled) { _ in refreshProvisioningAudit() }
                .onChange(of: altServerDeviceIdentifier) { _ in refreshProvisioningAudit() }
                .onChange(of: anisetteModeRaw) { _ in refreshProvisioningAudit() }
                .onChange(of: remoteAnisetteServerAddress) { _ in refreshProvisioningAudit() }
                .onChange(of: signer.phase) { _ in
                    if case .signing = signer.phase { signNotice = nil }
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
                GlassInputRow(icon: "lock.fill", label: "P12 password", placeholder: "Required", text: $password, isSecure: true)
            }
        }
    }

    private var certificateRow: some View {
        Button {
            showCertSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 22)
                Text("Certificate (.p12)").font(T.sans(15, .medium)).foregroundColor(T.ink)
                Spacer(minLength: 8)
                if let cert = certStore.selected {
                    let expiry = P12Inspector.expiry(cert.notAfter)
                    GlassStatusPill(text: expiry.text, color: expiry.tone.color(in: T))
                    Text(cert.displayName)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                } else {
                    Text("Choose…")
                        .font(T.sans(13, .medium))
                        .foregroundColor(T.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    private var profileRow: some View {
        Button {
            showProfileSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 22)
                Text("Profile (.mobileprovision)").font(T.sans(15, .medium)).foregroundColor(T.ink)
                Spacer(minLength: 8)
                if let profile = profileStore.selected {
                    let expiry = P12Inspector.expiry(profile.notAfter)
                    GlassStatusPill(text: expiry.text, color: expiry.tone.color(in: T))
                    Text(profile.displayName)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                } else {
                    Text("Choose…")
                        .font(T.sans(13, .medium))
                        .foregroundColor(T.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    // MARK: - Options

    private var optionsSection: some View {
        GlassSection("Options") {
            GlassInputRow(icon: "curlybraces", label: "New bundle ID", placeholder: "Optional", text: $bundleId)
            GlassRowDivider()
            GlassToggleRow(label: "Remove app extensions", isOn: $removeExtensions)
            GlassRowDivider()
            GlassToggleRow(label: "Enable Files import / sharing", isOn: $enableDocuments)
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
                        .tint(.white)
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
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .glassSurface(.button)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule2, lineWidth: AppStroke.hairline)
            }
            .shimmer(isActive: signing)
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
                    if installCoordinator.lastError != nil, !installCoordinator.isInstalling {
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

    private func stageIPA(_ source: URL, fallbackToSource: Bool = false) {
        let localURL = signer.stage(source) ?? (fallbackToSource ? source : nil)
        guard let localURL else {
            ipaURL = nil
            preflightState = .failed("The IPA could not be copied into ForgeSign storage.")
            return
        }

        ipaURL = localURL
        provisioningAudit = nil
        signer.pruneStagedArchives(keeping: localURL)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            ipaURL = nil
            preflightState = .failed("The staged IPA is no longer available. Please choose it again.")
            return
        }
        preflightState = .inspecting
        let temporaryDirectory = signer.tempDir

        Task.detached(priority: .utility) {
            let result = IPAPreflightService.inspect(ipa: localURL,
                                                      temporaryDirectory: temporaryDirectory)
            await MainActor.run {
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
    }

    private func stageDylib(_ source: URL) {
        dylibURL = signer.stage(source, as: source.lastPathComponent)
    }

    private var effectivePassword: String? {
        if let cert = certStore.selected, let saved = certStore.savedPassword(for: cert) {
            return saved
        }
        return password.isEmpty ? nil : password
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
        if profileStore.isRefreshingMetadata { return "Reading provisioning profiles…" }

        if automaticProvisioningEnabled {
            if !isAppleAccountReady {
                if canSignManually {
                    return "Apple Account details are incomplete — ForgeSign will sign with the selected certificate and profile."
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

    private var canSignManually: Bool {
        certStore.selected != nil && profileStore.selected != nil && effectivePassword != nil
    }

    private func sign(allowAutomaticProvisioning: Bool = true) {
        signNotice = nil
        guard let ipa = ipaURL else {
            signNotice = "Choose an IPA first — there is nothing to sign yet."
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
                deviceIdentifier: altServerDeviceIdentifier
            )
            provisioningAudit = audit
            // Apple is only contacted when the imported certificate and
            // profiles cannot cover this IPA; a working manual setup never
            // waits on (or fails with) Apple's sign-in service.
            if isAppleAccountReady && (!canSignManually || !audit.isReady) {
                obtainMissingProfiles(inspection: inspection,
                                      audit: audit,
                                      certificate: certStore.selected)
                return
            }
        }

        guard let cert = certStore.selected,
              let pw = effectivePassword,
              let profile = profileStore.selected else {
            signNotice = allowAutomaticProvisioning
                ? "Signing needs a certificate (.p12 with its password) and a provisioning profile. Add them under Input, or enter your Apple Account details under Provisioning so ForgeSign can create them."
                : "ForgeSign could not select the certificate or profile it just created. Tap Sign again, or import a certificate and profile manually."
            return
        }
        let p12 = certStore.fileURL(for: cert)
        let audit: ProvisioningAudit?
        if case .ready(let inspection) = preflightState {
            audit = ProvisioningAuditService.makeAudit(
                inspection: inspection,
                profiles: profileStore.profiles,
                preferredProfileID: profile.id,
                certificate: cert,
                requestedBundleID: bundleId,
                removeExtensions: removeExtensions,
                deviceIdentifier: automaticProvisioningEnabled && isAppleAccountReady
                    ? altServerDeviceIdentifier
                    : ProvisioningAuditService.currentDeviceIdentifier
            )
        } else {
            audit = nil
        }
        if let audit {
            provisioningAudit = audit
            if let blocker = audit.rows.first(where: { $0.kind != .app && $0.state.isBlocking }) {
                signNotice = "\(blocker.kind.displayName) \(blocker.resolvedBundleID): \(blocker.detail) "
                    + (canSignWithoutExtensions
                        ? "Import a matching profile, or sign without app extensions (the app works; features like its share sheet are dropped)."
                        : "Import a matching profile or use Apple Account provisioning.")
                return
            }
        }

        let plannedIDs = audit?.selectedProfileIDs ?? []
        let profileFiles: [ProfileRecord]
        if !plannedIDs.isEmpty {
            let resolved = plannedIDs.compactMap { id in
                profileStore.profiles.first { $0.id == id }
            }
            profileFiles = resolved.contains(where: { $0.id == profile.id })
                ? resolved : [profile] + resolved
        } else {
            // Preserve the manual path if inspection is unavailable.
            profileFiles = [profile] + profileStore.profiles.filter {
                $0.id != profile.id && $0.profileIsAuthentic
            }
        }
        let profileURLs = profileFiles.map { profileStore.fileURL(for: $0) }
        let profileNames = profileFiles.map(\.displayName)
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
        install.installStatus = ""
        install.installServer?.stop()
        install.installServer = nil
        InstallKeepAlive.shared.stop()
        let output = history.uniqueOutputURL(for: ipa.lastPathComponent)
        let outName = output.lastPathComponent
        let partialOutput = signer.tempDir.appendingPathComponent("signed-\(UUID().uuidString).ipa.partial")
        let tempDir = signer.tempDir
        let bid = bundleId.trimmingCharacters(in: .whitespaces)
        let rmExt = removeExtensions
        let enDocs = enableDocuments
        let selectedDylib = dylibURL
        let injectExt = injectIntoExtensions

        Task.detached(priority: .userInitiated) {
            for (index, profileURL) in profileURLs.enumerated() {
                let validation = SigningService.validateSigningAsset(
                    p12: p12, password: pw, profile: profileURL
                )
                guard validation.ok else {
                    let name = profileNames.indices.contains(index) ? profileNames[index] : profileURL.lastPathComponent
                    await MainActor.run {
                        signer.phase = .failed("Profile “\(name)” cannot be used with the selected certificate: \(validation.message)")
                    }
                    return
                }
            }

            let signingIPA: URL
            var preparedIPA: URL?
            if let selectedDylib {
                let prepared = tempDir.appendingPathComponent("fs-injected-\(UUID().uuidString).ipa")
                switch DylibInjectionService.prepare(ipa: ipa,
                                                      dylib: selectedDylib,
                                                      output: prepared,
                                                      temporaryDirectory: tempDir,
                                                      injectIntoExtensions: injectExt) {
                case .success:
                    signingIPA = prepared
                    preparedIPA = prepared
                case .failure(let error):
                    await MainActor.run {
                        signer.phase = .failed(error.localizedDescription)
                    }
                    return
                }
            } else {
                signingIPA = ipa
            }

            let result = SigningService.sign(ipa: signingIPA, p12: p12, password: pw, profiles: profileURLs,
                                             bundleId: bid, output: partialOutput, tempDir: tempDir,
                                             removeExtensions: rmExt, enableDocuments: enDocs)
            if let preparedIPA {
                try? FileManager.default.removeItem(at: preparedIPA)
            }
            let verification = result.ok
                ? SigningService.verify(ipa: partialOutput, temporaryDirectory: tempDir)
                : (ok: false, message: result.message)
            await MainActor.run {
                defer { signer.cleanTemp() }
                guard result.ok, verification.ok else {
                    try? FileManager.default.removeItem(at: partialOutput)
                    signer.phase = .failed(result.ok ? verification.message : result.message)
                    return
                }
                do {
                    try FileManager.default.moveItem(at: partialOutput, to: output)
                    signedIPA = output
                    signedBundleId = result.signedBundleId
                    signedVersion = result.signedVersion
                    signer.phase = .done(result.message)
                    let record = history.append(inputName: ipa.lastPathComponent,
                                                outputName: outName,
                                                bundleId: result.signedBundleId,
                                                version: result.signedVersion,
                                                certificateCN: certCN,
                                                profileExpiresAt: profileExpiry)
                    lastRecordID = record.id
                    if retainSource {
                        // Retain the *original* package, never the signed output.
                        let kept = refreshSources.retain(ipa, for: record.id)
                        history.setRefreshSourceName(kept, for: record.id)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: partialOutput)
                    signer.phase = .failed("The signed IPA could not be finalized in the library.")
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
                certStore.selectedID = importedCertificate.id
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
                    provisioningWarning = "Apple Account provisioning could not finish: \(error.localizedDescription) Checking the imported profiles for manual signing."
                    signer.phase = .idle
                    sign(allowAutomaticProvisioning: false)
                } else {
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
