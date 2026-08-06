import SwiftUI

/// Library tab — persistent history of signed apps with share / reinstall /
/// delete actions.
struct LibraryView: View {
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.forgeTheme) private var T

    var onInstall: (SigningRecord) -> Void = { _ in }

    @State private var activeRecord: SigningRecord?
    @State private var shareRecord: SigningRecord?

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeBackdrop()
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
                Button("Delete", role: .destructive) { history.delete(record) }
            }
            .sheet(item: $shareRecord) { record in
                ShareSheet(items: [history.outputURL(for: record)])
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ForgeGlassLogoView(size: 68)

            Text("Library")
                .font(T.display(30))
                .foregroundColor(T.ink)

            MonoText(text: "SIGNED APP HISTORY", size: 10, weight: .semibold, color: T.ink3)
        }
        .padding(.top, 28)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
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
        .padding(.horizontal, 16)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
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
                        .font(T.mono(12))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.bundleId)
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    statusPill(record)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(T.mono(9))
                        .foregroundColor(T.ink4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
            case .installed:
                GlassStatusPill(text: "installed", color: T.good)
            case .failed:
                GlassStatusPill(text: "failed", color: T.bad)
            }
        }
    }
}
