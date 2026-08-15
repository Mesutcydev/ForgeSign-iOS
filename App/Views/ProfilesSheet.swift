import SwiftUI

/// Picker + manager for remembered provisioning profiles. Shows remaining
/// validity per profile (often fixed at 365 days) and imports new
/// .mobileprovision files directly — no password, just saved on-device.
struct ProfilesSheet: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T

    @State private var showImporter = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header

                        if store.profiles.isEmpty {
                            emptyState
                        } else {
                            GlassSection("Saved") {
                                VStack(spacing: 0) {
                                    ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                                        row(profile)
                                        if index < store.profiles.count - 1 {
                                            GlassRowDivider()
                                        }
                                    }
                                }
                            }
                        }

                        if let error {
                            Text(error)
                                .font(T.mono(10))
                                .foregroundColor(T.bad)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, T.pad)
                                .padding(.top, 16)
                        }

                        GlassSecondaryButton(label: "Import Profile…", systemImage: "plus") {
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
                .fullScreenCover(isPresented: $showImporter) {
                    ForgeDocumentPicker {
                        guard $0.pathExtension.lowercased() == "mobileprovision" else {
                            error = "Choose a .mobileprovision file."
                            Task { @MainActor in showImporter = false }
                            return
                        }
                        importProfile(from: $0)
                        Task { @MainActor in showImporter = false }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: 8) {
            CaptionText(text: "Saved Profiles")
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
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text("No saved profiles")
                .font(T.sans(15))
                .foregroundColor(T.ink)
            MonoText(text: "Import a .mobileprovision once — it stays on this device.", size: 10, color: T.ink3)
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

    private func row(_ profile: ProfileRecord) -> some View {
        let isSelected = profile.id == store.selectedID
        let expiry = P12Inspector.expiry(profile.notAfter)

        return Button {
            store.selectedID = profile.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? T.accent : T.ink4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(T.sans(15, .medium))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(profile.applicationIdentifier ?? profile.filename)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let devices = profile.provisionedDeviceCount {
                            Text("\(devices) DEVICES")
                                .font(T.mono(8))
                                .foregroundColor(T.ink3)
                        } else if profile.provisionsAllDevices == true {
                            Text("ALL DEVICES")
                                .font(T.mono(8))
                                .foregroundColor(T.ink3)
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
            Button("Delete", role: .destructive) { store.delete(profile) }
        }
    }

    private func importProfile(from url: URL) {
        switch store.importProfile(from: url) {
        case .success:
            error = nil
            dismiss()
        case .failure(let failure):
            error = failure.errorDescription
        }
    }
}
