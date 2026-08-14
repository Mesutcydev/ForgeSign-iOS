import SwiftUI

/// Sources tab — add AltStore-style repository URLs, browse their apps, and
/// download an IPA. A finished download is handed to the Sign tab (via
/// `RepositoryStore.pendingIPA`) so the user signs + installs exactly as today.
struct SourcesView: View {
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.forgeTheme) private var T

    @State private var newRepoURL = ""
    @State private var addError: String?
    @State private var selectedRepo: Repository?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        addSection
                        if let addError {
                            Text(addError)
                                .font(T.mono(10))
                                .foregroundColor(T.bad)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, T.pad)
                                .padding(.top, 12)
                        }
                        reposSection
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(item: $selectedRepo) { repo in
                    RepoDetailSheet(repo: repo)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: T.gap) {
            ForgeGlassLogoView(size: 60)
            Text("Sources")
                .font(T.display(30))
                .foregroundColor(T.ink)
            MonoText(text: "APP REPOSITORIES", size: 10, weight: .semibold, color: T.ink3)
        }
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    private var addSection: some View {
        VStack(spacing: 0) {
            GlassSection("Add Repository") {
                GlassInputRow(icon: "link", label: "URL",
                              placeholder: "https://…/repos.json", text: $newRepoURL)
            }
            GlassPrimaryButton(label: "Add Repository", systemImage: "plus",
                               action: add,
                               disabled: newRepoURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, T.pad)
                .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var reposSection: some View {
        if store.repositories.isEmpty {
            emptyState
        } else {
            GlassSection("Repositories") {
                VStack(spacing: 0) {
                    ForEach(Array(store.repositories.enumerated()), id: \.element.id) { index, repo in
                        repoRow(repo)
                        if index < store.repositories.count - 1 {
                            GlassRowDivider()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text("No repositories yet")
                .font(T.sans(15))
                .foregroundColor(T.ink)
            MonoText(text: "Add a source URL to browse and download apps.", size: 10, color: T.ink3)
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

    private func repoRow(_ repo: Repository) -> some View {
        Button {
            selectedRepo = repo
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 38, height: 38)
                    .fClearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.name)
                        .font(T.sans(15, .medium))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(repo.url.host ?? repo.url.absoluteString)
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let count = store.catalog[repo.id]?.apps.count {
                    GlassStatusPill(text: "\(count) apps", color: T.accent)
                }
                if repo.url.scheme?.lowercased() == "http" {
                    GlassStatusPill(text: "HTTP", color: T.warn)
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
        .contextMenu {
            Button("Delete", role: .destructive) { store.remove(repo) }
        }
    }

    private func add() {
        switch store.add(urlString: newRepoURL) {
        case .success:
            newRepoURL = ""
            addError = nil
        case .failure(let failure):
            addError = failure.errorDescription
        }
    }
}

// MARK: - Repo detail (apps list)

/// Sheet listing one repository's apps with a per-app download ("Get") action.
struct RepoDetailSheet: View {
    let repo: Repository

    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss

    @State private var selectedApp: RepoApp?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        content
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { await store.refresh(repo) }
                .sheet(item: $selectedApp) { app in
                    RepoAppDetailSheet(app: app)
                }
            }
        }
        .presentationDetents([.large])
        .task { if store.catalog[repo.id] == nil { await store.refresh(repo) } }
        .onChange(of: store.pendingIPA) { ipa in
            // Download finished → close the sheet so the Sign tab takes over.
            if ipa != nil { dismiss() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CaptionText(text: repo.name)
            Rectangle().fill(T.rule).frame(height: 1)
            Button { dismiss() } label: {
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

    @ViewBuilder
    private var content: some View {
        if let source = store.catalog[repo.id] {
            if source.apps.isEmpty {
                message(icon: "tray", "This source has no apps.")
            } else {
                GlassSection("Apps") {
                    // Some public sources contain hundreds of apps. Building
                    // every row and starting every icon request at once can
                    // exceed the memory budget on iPhone, so render on demand.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(source.apps.enumerated()), id: \.element.id) { index, app in
                            appRow(app)
                            if index < source.apps.count - 1 {
                                GlassRowDivider()
                            }
                        }
                    }
                }
                if let downloadError = store.downloadError {
                    Text(downloadError)
                        .font(T.mono(10))
                        .foregroundColor(T.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, T.pad)
                        .padding(.top, 12)
                }
            }
        } else if store.loadingRepoID == repo.id {
            loadingState
        } else if let error = store.fetchError[repo.id] {
            message(icon: "exclamationmark.triangle", error)
        }
    }

    private var loadingState: some View {
        VStack(spacing: T.gap) {
            ProgressView().tint(T.accent)
            MonoText(text: "Loading repository…", size: 10, color: T.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.top, 24)
    }

    private func message(icon: String, _ text: String) -> some View {
        VStack(spacing: T.gap) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(text)
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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

    private func appRow(_ app: RepoApp) -> some View {
        HStack(spacing: 12) {
            appIcon(app)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let version = app.version {
                        Text("v\(version)").font(T.mono(10)).foregroundColor(T.ink3)
                    }
                    if let size = app.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(T.mono(10)).foregroundColor(T.ink3)
                    }
                    if let dev = app.developerName {
                        Text(dev).font(T.mono(10)).foregroundColor(T.ink4)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if app.versions.count > 1 {
                        Text("\(app.versions.count) versions")
                            .font(T.mono(9))
                            .foregroundColor(T.accent2)
                    }
                    if let description = app.localizedDescription, !description.isEmpty {
                        Text(description)
                            .font(T.mono(9))
                            .foregroundColor(T.ink4)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                selectedApp = app
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(T.ink3)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassTactileButtonStyle())

            getButton(app)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func appIcon(_ app: RepoApp) -> some View {
        AsyncImage(url: app.iconURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Image(systemName: "app.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(T.accent2)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fClearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func getButton(_ app: RepoApp) -> some View {
        if store.activeDownloadID == app.id {
            ProgressView().tint(T.accent).frame(width: 52)
        } else {
            Button {
                Task { await store.download(app) }
            } label: {
                Text("GET")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(app.downloadURL == nil ? T.ink4 : T.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay {
                        Capsule().stroke((app.downloadURL == nil ? T.ink4 : T.accent).opacity(0.4),
                                         lineWidth: AppStroke.hairline)
                    }
            }
            .buttonStyle(GlassTactileButtonStyle())
            .disabled(app.downloadURL == nil || store.activeDownloadID != nil)
        }
    }
}

/// Detail inspector for a source app. It is intentionally read-only; the
/// existing GET action remains the only path that starts a download.
struct RepoAppDetailSheet: View {
    let app: RepoApp

    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        summary

                        if let description = app.localizedDescription, !description.isEmpty {
                            GlassSection("Description") {
                                Text(description)
                                    .font(T.sans(14))
                                    .foregroundColor(T.ink2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(16)
                            }
                        }

                        GlassSection("Metadata") {
                            VStack(spacing: 0) {
                                detailRow("Bundle ID", app.bundleIdentifier.isEmpty ? "unknown" : app.bundleIdentifier)
                                GlassRowDivider()
                                detailRow("Current version", app.version ?? "unknown")
                                if let developer = app.developerName {
                                    GlassRowDivider()
                                    detailRow("Developer", developer)
                                }
                                if let size = app.size {
                                    GlassRowDivider()
                                    detailRow("Download size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                }
                            }
                        }

                        if app.versions.count > 1 {
                            GlassSection("Published versions") {
                                VStack(spacing: 0) {
                                    ForEach(app.versions) { version in
                                        HStack(spacing: 10) {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(T.accent2)
                                            Text(version.version ?? "unknown")
                                                .font(T.mono(12, .medium))
                                                .foregroundColor(T.ink)
                                            Spacer(minLength: 8)
                                            if let size = version.size {
                                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                                    .font(T.mono(10))
                                                    .foregroundColor(T.ink3)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        if version.id != app.versions.last?.id {
                                            GlassRowDivider()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: 8) {
            CaptionText(text: app.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Rectangle().fill(T.rule).frame(height: 1)
            Button { dismiss() } label: {
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

    private var summary: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(T.sans(18, .semibold))
                    .foregroundColor(T.ink)
                if let developer = app.developerName {
                    Text(developer)
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 22)
    }

    private var appIcon: some View {
        AsyncImage(url: app.iconURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Image(systemName: "app.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(T.accent2)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .fClearGlass(in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GlassRow(label: label) {
            Text(value)
                .font(T.mono(10))
                .foregroundColor(T.ink2)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .trailing)
        }
    }
}
