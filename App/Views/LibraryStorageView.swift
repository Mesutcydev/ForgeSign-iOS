import SwiftUI

/// Storage controls live with the Library because the signed IPA is the main
/// long-lived artifact. A cleanup never removes an app installed by iOS.
struct LibraryStorageView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var repositories: RepositoryStore
    @EnvironmentObject private var refreshSources: RefreshSourceStore
    @EnvironmentObject private var signer: SigningService
    @EnvironmentObject private var installer: InstallCoordinator
    @Environment(\.forgeTheme) private var T

    @State private var usage = Usage()
    @State private var cleanup: Cleanup?
    @State private var cleanupError: String?

    private struct Usage {
        var signed: Int64 = 0
        var delivered: Int64 = 0
        var downloads: Int64 = 0
        var originals: Int64 = 0
        var staging: Int64 = 0

        var total: Int64 { signed + downloads + originals + staging }
    }

    private enum Cleanup: String {
        case delivered, allSigned, downloads, originals, staging

        var title: LocalizedStringKey {
            switch self {
            case .delivered: "Clear delivered signed IPAs?"
            case .allSigned: "Clear all signed IPAs?"
            case .downloads: "Clear downloaded IPAs?"
            case .originals: "Clear kept originals?"
            case .staging: "Clear current input?"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .delivered:
                "ForgeSign will remove signed copies already delivered to iOS. Library history and installed apps remain. These copies cannot be shared or reinstalled until you sign them again."
            case .allSigned:
                "ForgeSign will remove every signed IPA it stores. Library history and installed apps remain. Sharing or reinstalling one will require signing it again."
            case .downloads:
                "Repository downloads will be removed. Apps and signed IPAs already in the Library remain. You can download these packages again."
            case .originals:
                "Original packages kept for refresh will be removed. Refresh will require you to pick the original IPA again."
            case .staging:
                "The currently selected IPA and injected library will be removed from ForgeSign's signing cache. Pick them again to sign."
            }
        }

        var buttonTitle: LocalizedStringKey {
            switch self {
            case .delivered: "Clear delivered copies"
            case .allSigned: "Clear all signed IPAs"
            case .downloads: "Clear downloads"
            case .originals: "Clear originals"
            case .staging: "Clear current input"
            }
        }
    }

    private var busy: Bool {
        installer.isInstalling || signer.phase == .signing || signer.phase == .provisioning
    }

    var body: some View {
        GlassSection("Storage") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("IPA and input copies")
                        .font(T.sans(14, .semibold))
                        .foregroundColor(T.ink)
                    Spacer()
                    Text(size(usage.total))
                        .font(T.mono(13, .semibold))
                        .foregroundColor(T.accent2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)

                GlassRowDivider()
                storageLine("Signed IPAs", bytes: usage.signed)
                storageLine("Repository downloads", bytes: usage.downloads)
                storageLine("Kept originals", bytes: usage.originals)
                storageLine("Current signing input", bytes: usage.staging)

                Text("Installed apps use their own iOS storage. This total covers the large copies you can clear here.")
                    .font(T.sans(11))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                if usage.delivered > 0 {
                    GlassRowDivider()
                    cleanupButton("Clear delivered copies (\(size(usage.delivered)))", target: .delivered,
                                  disabled: busy)
                }
                if usage.signed > 0 {
                    GlassRowDivider()
                    cleanupButton("Clear all signed IPAs", target: .allSigned, disabled: busy)
                }
                if usage.downloads > 0 {
                    GlassRowDivider()
                    cleanupButton("Clear repository downloads", target: .downloads,
                                  disabled: repositories.activeDownloadID != nil || repositories.pendingIPA != nil)
                }
                if usage.originals > 0 {
                    GlassRowDivider()
                    cleanupButton("Clear kept originals", target: .originals, disabled: busy)
                }
                if usage.staging > 0 {
                    GlassRowDivider()
                    cleanupButton("Clear current signing input", target: .staging,
                                  disabled: !signer.canClearStaging)
                }
            }
        }
        .onAppear { refreshUsage() }
        .onChange(of: history.records) { _ in refreshUsage() }
        .onChange(of: repositories.activeDownloadID) { _ in refreshUsage() }
        .onChange(of: refreshSources.totalBytes) { _ in refreshUsage() }
        .onChange(of: signer.stagingResetID) { _ in refreshUsage() }
        .confirmationDialog(
            cleanup?.title ?? "Clear storage?",
            isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } }),
            titleVisibility: .visible
        ) {
            if let cleanup {
                Button(cleanup.buttonTitle, role: .destructive) { run(cleanup) }
            }
        } message: {
            Text(cleanup?.detail ?? "")
        }
        .alert("Some files could not be removed", isPresented: Binding(
            get: { cleanupError != nil }, set: { if !$0 { cleanupError = nil } }
        )) {
            Button("OK", role: .cancel) { cleanupError = nil }
        } message: {
            Text(cleanupError ?? "")
        }
    }

    private func storageLine(_ title: LocalizedStringKey, bytes: Int64) -> some View {
        HStack {
            Text(title)
                .font(T.sans(12))
                .foregroundColor(T.ink2)
            Spacer()
            Text(size(bytes))
                .font(T.mono(11))
                .foregroundColor(T.ink3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func cleanupButton(_ title: LocalizedStringKey, target: Cleanup, disabled: Bool) -> some View {
        Button { cleanup = target } label: {
            HStack {
                Text(title)
                    .font(T.sans(12, .semibold))
                Spacer()
                Image(systemName: "trash")
            }
            .foregroundColor(T.bad)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }

    private func refreshUsage() {
        usage = Usage(signed: history.signedCopyBytes,
                      delivered: history.deliveredCopyBytes,
                      downloads: repositories.downloadedBytes,
                      originals: refreshSources.storedBytes,
                      staging: signer.stagedBytes)
    }

    private func run(_ target: Cleanup) {
        let result: (removed: Int, failed: Int)
        switch target {
        case .delivered:
            guard !busy else { return }
            result = history.clearSignedCopies(deliveredOnly: true)
        case .allSigned:
            guard !busy else { return }
            result = history.clearSignedCopies(deliveredOnly: false)
        case .downloads:
            guard repositories.activeDownloadID == nil, repositories.pendingIPA == nil else { return }
            result = repositories.clearDownloads()
        case .originals:
            guard !busy else { return }
            result = refreshSources.removeAll()
        case .staging:
            guard signer.canClearStaging else { return }
            result = signer.clearStaging()
        }
        refreshUsage()
        if result.failed > 0 {
            cleanupError = "\(result.failed) file(s) could not be removed. The remaining storage is shown above."
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
