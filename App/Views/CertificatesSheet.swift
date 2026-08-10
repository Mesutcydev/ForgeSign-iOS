import SwiftUI
import UniformTypeIdentifiers

/// Picker + manager for remembered signing certificates. Shows remaining
/// validity per certificate, imports new .p12 files (validated against a
/// password) and optionally stores the password in the Keychain.
struct CertificatesSheet: View {
    @EnvironmentObject private var store: CertificateStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T

    @State private var showImporter = false
    @State private var pendingURL: URL?
    @State private var pendingPassword = ""
    @State private var rememberPassword = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header

                        if let pendingURL {
                            verifyCard(pendingURL)
                        }

                        if store.certificates.isEmpty && pendingURL == nil {
                            emptyState
                        } else if !store.certificates.isEmpty {
                            GlassSection("Saved") {
                                VStack(spacing: 0) {
                                    ForEach(Array(store.certificates.enumerated()), id: \.element.id) { index, cert in
                                        row(cert)
                                        if index < store.certificates.count - 1 {
                                            GlassRowDivider()
                                        }
                                    }
                                }
                            }
                        }

                        GlassSecondaryButton(label: "Import Certificate…", systemImage: "plus") {
                            showImporter = true
                        }
                        .padding(.horizontal, T.pad)
                        .padding(.top, 24)
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .fileImporter(isPresented: $showImporter,
                              allowedContentTypes: [.pkcs12, UTType(filenameExtension: "pfx") ?? .pkcs12]) { result in
                    if case .success(let url) = result {
                        pendingURL = url
                        pendingPassword = ""
                        error = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: 8) {
            CaptionText(text: "Saved Certificates")
            Rectangle().fill(T.rule).frame(height: 1)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(T.ink2)
                    .frame(width: 30, height: 30)
                    .fClearGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(GlassTactileButtonStyle())
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "key.fill")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text("No saved certificates")
                .font(T.sans(15))
                .foregroundColor(T.ink)
            MonoText(text: "Import a .p12 once — it stays on this device.", size: 10, color: T.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func row(_ cert: CertificateRecord) -> some View {
        let isSelected = cert.id == store.selectedID
        let expiry = P12Inspector.expiry(cert.notAfter)

        return Button {
            store.selectedID = cert.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? T.accent : T.ink4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cert.displayName)
                        .font(T.sans(15, .medium))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(cert.organization ?? cert.filename)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let team = cert.teamID {
                            Text("TEAM \(team.uppercased())")
                                .font(T.mono(8))
                                .foregroundColor(T.ink3)
                        }
                        if cert.hasSavedPassword {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(T.accent2)
                        }
                    }
                }
                Spacer(minLength: 8)
                GlassStatusPill(text: expiry.text, color: expiry.tone.color(in: T))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
        .contextMenu {
            Button("Delete", role: .destructive) { store.delete(cert) }
        }
    }

    private func verifyCard(_ url: URL) -> some View {
        VStack(spacing: T.gap) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                Text(url.lastPathComponent)
                    .font(T.mono(11))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            SecureField("P12 password", text: $pendingPassword)
                .textFieldStyle(.plain)
                .font(T.mono(13))
                .foregroundColor(T.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(T.surface3)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }

            HStack(spacing: 12) {
                Text("Remember password in Keychain")
                    .font(T.sans(13, .medium))
                    .foregroundColor(T.ink)
                Spacer(minLength: 8)
                GlassToggle(isOn: $rememberPassword)
            }

            if let error {
                Text(error)
                    .font(T.mono(10))
                    .foregroundColor(T.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                GlassSecondaryButton(label: "Cancel") {
                    pendingURL = nil
                    pendingPassword = ""
                    error = nil
                }
                GlassPrimaryButton(label: "Verify & Save", systemImage: "checkmark.seal") {
                    verify(url)
                }
            }
        }
        .padding(16)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func verify(_ url: URL) {
        switch store.importCertificate(from: url, password: pendingPassword,
                                       rememberPassword: rememberPassword) {
        case .success:
            pendingURL = nil
            pendingPassword = ""
            error = nil
        case .failure(let failure):
            error = failure.errorDescription
        }
    }
}
