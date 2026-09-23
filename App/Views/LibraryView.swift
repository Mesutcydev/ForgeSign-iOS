import SwiftUI

/// Library tab — persistent history of signed apps with share / reinstall /
/// delete actions.
struct LibraryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var refreshSources: RefreshSourceStore
    @Environment(\.forgeTheme) private var T

    var onInstall: (SigningRecord) -> Void = { _ in }
    var onRefresh: (SigningRecord) -> Void = { _ in }

    @State private var activeRecord: SigningRecord?
    @State private var shareRecord: SigningRecord?
    @AppStorage("retainRefreshSources") private var retainRefreshSources = false

    private var scan: RefreshScan { RefreshScanner.scan(history.records) }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header

                        if history.records.isEmpty {
                            emptyState
                        } else {
                            GlassSection("Library") {
                                VStack(spacing: 0) {
                                    ForEach(Array(history.records.enumerated()), id: \.element.id) { index, record in
                                        row(record)
                                        if index < history.records.count - 1 {
                                            GlassRowDivider()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
            }
            .confirmationDialog(
                activeRecord?.outputName ?? "",
                isPresented: Binding(get: { activeRecord != nil },
                                     set: { if !$0 { activeRecord = nil } }),
                presenting: activeRecord
            ) { record in
                if history.fileExists(for: record) {
                    Button("Install on Device") { onInstall(record) }
                    Button("Share / Save IPA") { shareRecord = record }
                }
                if refreshSources.sourceURL(for: record.id) != nil {
                    Button("Refresh — re-sign \(refreshSources.sourceName(for: record.id) ?? "the kept original")") {
                        onRefresh(record)
                    }
                    Button("Drop kept original") { refreshSources.removeSource(for: record.id) }
                }
                if history.fileExists(for: record) {
                    Button("Delete signed IPA", role: .destructive) { history.delete(record) }
                } else {
                    Button("Remove from Library", role: .destructive) { history.delete(record) }
                }
            }
            .sheet(item: $shareRecord) { record in
                ShareSheet(items: [history.outputURL(for: record)])
            }
        }
        .task {
            history.refreshFileAvailability()
        }
    }

    private var header: some View {
        VStack(spacing: T.gap) {
            ForgeGlassLogoView(size: 60)

            Text("Library")
                .font(T.display(30))
                .foregroundColor(T.ink)

            MonoText(text: "SIGNED APP HISTORY", size: 10, weight: .semibold, color: T.ink3)

            if let summary = scan.summary {
                GlassStatusPill(text: summary, color: T.warn)
            }

            Toggle(isOn: $retainRefreshSources) {
                MonoText(text: "KEEP ORIGINALS FOR REFRESH", size: 9, weight: .semibold, color: T.ink3)
            }
            .toggleStyle(.switch)
            .tint(T.accent)
            .padding(.horizontal, 24)

            if retainRefreshSources, refreshSources.totalBytes > 0 {
                MonoText(text: "KEPT \(ByteCountFormatter.string(fromByteCount: refreshSources.totalBytes, countStyle: .file))",
                         size: 9, color: T.ink4)
            }
        }
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "shippingbox")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text("No signed apps yet")
                .font(T.sans(15))
                .foregroundColor(T.ink)
            MonoText(text: "Sign an IPA and it will be kept here.", size: 10, color: T.ink3)
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

    private func row(_ record: SigningRecord) -> some View {
        Button {
            activeRecord = record
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "app.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 38, height: 38)
                    .fClearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.outputName)
                        .font(T.mono(12, .medium))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(record.bundleId)
                            .font(T.mono(10, .medium))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !record.version.isEmpty {
                            Text("v\(record.version)")
                                .font(T.mono(9))
                                .foregroundColor(T.accent2)
                        }
                    }
                    if let certificateCN = record.certificateCN, !certificateCN.isEmpty {
                        Text(certificateCN)
                            .font(T.mono(9))
                            .foregroundColor(T.ink4)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let expiryText = RefreshPlanner.expiryText(record.profileExpiresAt) {
                        Text(expiryText)
                            .font(T.mono(9, .medium))
                            .foregroundColor(expiryColor(record))
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    statusPill(record)
                    refreshPill(record)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(T.mono(9, .medium))
                        .foregroundColor(T.ink4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    @ViewBuilder
    private func statusPill(_ record: SigningRecord) -> some View {
        if !history.fileExists(for: record) {
            GlassStatusPill(text: "missing", color: T.warn)
        } else {
            switch record.installState {
            case .signed:
                GlassStatusPill(text: "signed", color: T.accent)
            case .installing:
                GlassStatusPill(text: "installing", color: T.warn)
            case .delivered:
                GlassStatusPill(text: "delivered", color: T.good)
            case .installed:
                GlassStatusPill(text: "installed", color: T.good)
            case .failed:
                GlassStatusPill(text: "failed", color: T.bad)
            }
        }
    }

    @ViewBuilder
    private func refreshPill(_ record: SigningRecord) -> some View {
        if RefreshPlanner.shouldRefresh(expiry: record.profileExpiresAt) {
            let canRefresh = refreshSources.sourceURL(for: record.id) != nil
            GlassStatusPill(text: canRefresh ? "refresh due" : "action needed",
                            color: canRefresh ? T.warn : T.bad)
        } else if refreshSources.sourceURL(for: record.id) != nil {
            GlassStatusPill(text: "refresh ready", color: T.accent2)
        }
    }

    private func expiryColor(_ record: SigningRecord) -> Color {
        guard let expiry = record.profileExpiresAt else { return T.ink4 }
        let interval = expiry.timeIntervalSinceNow
        if interval <= 0 { return T.bad }
        return interval <= RefreshPlanner.refreshWindow ? T.warn : T.ink3
    }
}
