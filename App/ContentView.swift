import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var signer = SigningService()

    @EnvironmentObject private var certStore: CertificateStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var install: InstallController
    @Environment(\.forgeTheme) private var T

    @State private var ipaURL: URL?
    @State private var password = ""
    @State private var bundleId = ""
    @State private var removeExtensions = false
    @State private var enableDocuments = false
    @State private var signedIPA: URL?
    @State private var signedBundleId = ""
    @State private var signedVersion = "1.0"
    @State private var lastRecordID: UUID?
    @State private var showIPAImporter = false
    @State private var showProfileSheet = false
    @State private var showCertSheet = false
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeBackdrop()
                ScrollView {
                    VStack(spacing: 0) {
                        header

                        inputSection
                        optionsSection
                        signButton

                        if case .failed(let message) = signer.phase {
                            errorCard(message)
                                .transition(.opacity)
                        }

                        if let signedIPA {
                            resultSection(signedIPA)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(AppAnimation.state, value: signer.phase == .signing)
                    .animation(AppAnimation.state, value: signedIPA != nil)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .toolbar(.hidden, for: .navigationBar)
                .fileImporter(isPresented: $showIPAImporter, allowedContentTypes: [.zip, UTType(filenameExtension: "ipa") ?? .zip]) { result in
                    if case .success(let url) = result { ipaURL = signer.stage(url) }
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
                .onChange(of: install.installStatus) { status in
                    if status.hasPrefix("Install failed"), let id = lastRecordID {
                        history.setInstallState(.failed, for: id)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            ForgeGlassLogoView(size: 68)

            Text("ForgeSign")
                .font(T.display(30))
                .foregroundColor(T.ink)

            MonoText(text: "ON-DEVICE IPA SIGNER", size: 10, weight: .semibold, color: T.ink3)
        }
        .padding(.top, 28)
        .padding(.bottom, 4)
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
                Text("Certificate (.p12)").font(T.sans(15)).foregroundColor(T.ink)
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
                        .font(T.sans(13))
                        .foregroundColor(T.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
                Text("Profile (.mobileprovision)").font(T.sans(15)).foregroundColor(T.ink)
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
                        .font(T.sans(13))
                        .foregroundColor(T.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
        return Button(action: sign) {
            HStack(spacing: 8) {
                if signing {
                    ProgressView()
                        .tint(.white)
                    Text("Signing…").font(T.sans(15, .semibold))
                } else {
                    Image(systemName: "signature")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sign IPA").font(T.sans(15, .semibold))
                }
            }
            .foregroundColor(T.isDark ? .white : T.ink)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .glassSurface(.button)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule2, lineWidth: AppStroke.hairline)
            }
            .shimmer(isActive: signing)
            .opacity(!canSign || signing ? 0.45 : 1)
        }
        .buttonStyle(GlassTactileButtonStyle())
        .disabled(!canSign || signing)
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }

    // MARK: - Error

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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fGlass(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.bad.opacity(0.35), lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                GlassRowDivider()

                GlassRow(label: "Bundle ID") {
                    Text(signedBundleId)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !install.installStatus.isEmpty {
                    GlassRowDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 11))
                            .foregroundColor(T.accent2)
                        Text(install.installStatus)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                GlassRowDivider()

                VStack(spacing: 10) {
                    GlassPrimaryButton(label: "Install on Device", systemImage: "arrow.down.app") {
                        startInstall()
                    }
                    if install.installServer != nil {
                        GlassSecondaryButton(label: "Install via Safari", systemImage: "safari") {
                            install.openInstallPage()
                        }
                    }
                    GlassSecondaryButton(label: "Share / Save signed IPA", systemImage: "square.and.arrow.up") {
                        showShare = true
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Logic

    private var effectivePassword: String? {
        if let cert = certStore.selected, let saved = certStore.savedPassword(for: cert) {
            return saved
        }
        return password.isEmpty ? nil : password
    }

    private var canSign: Bool {
        ipaURL != nil && certStore.selected != nil && profileStore.selected != nil && effectivePassword != nil
    }

    private func sign() {
        guard let ipa = ipaURL,
              let cert = certStore.selected,
              let pw = effectivePassword,
              let profile = profileStore.selected else { return }
        let p12 = certStore.fileURL(for: cert)
        let profileFile = profileStore.fileURL(for: profile)
        let certCN = cert.commonName

        signer.phase = .signing
        signedIPA = nil
        lastRecordID = nil
        install.installStatus = ""
        install.installServer?.stop()
        install.installServer = nil
        InstallKeepAlive.shared.stop()
        let outName = ipa.deletingPathExtension().lastPathComponent + "-signed.ipa"
        let output = history.signedDir.appendingPathComponent(outName)
        let tempDir = signer.tempDir
        let bid = bundleId.trimmingCharacters(in: .whitespaces)
        let rmExt = removeExtensions
        let enDocs = enableDocuments

        Task.detached(priority: .userInitiated) {
            let result = SigningService.sign(ipa: ipa, p12: p12, password: pw, profile: profileFile,
                                             bundleId: bid, output: output, tempDir: tempDir,
                                             removeExtensions: rmExt, enableDocuments: enDocs)
            await MainActor.run {
                if result.ok {
                    signedIPA = output
                    signedBundleId = result.signedBundleId
                    signedVersion = result.signedVersion
                    signer.phase = .done(result.message)
                    let record = history.append(inputName: ipa.lastPathComponent,
                                                outputName: outName,
                                                bundleId: result.signedBundleId,
                                                version: result.signedVersion,
                                                certificateCN: certCN)
                    lastRecordID = record.id
                } else {
                    signer.phase = .failed(result.message)
                }
            }
        }
    }

    private func startInstall() {
        guard let ipa = signedIPA else { return }
        let recordID = lastRecordID
        if let recordID {
            history.setInstallState(.installing, for: recordID)
        }
        install.onDelivered = {
            if let recordID {
                history.setInstallState(.installed, for: recordID)
            }
        }
        install.install(ipa: ipa, bundleId: signedBundleId, version: signedVersion)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
