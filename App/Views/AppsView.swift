import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var sourceStore: SourceStore
    @Environment(\.forgeTheme) private var T

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        
                        // 1. Featured Section
                        if !allApps.isEmpty {
                            featuredSection
                        }

                        // 2. All Apps List
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Must-Have Apps")
                                .font(T.sans(20, .bold))
                                .foregroundColor(T.ink)
                                .padding(.horizontal, 16)

                            if filteredApps.isEmpty {
                                Text(allApps.isEmpty ? "Loading apps..." : "No matching apps.")
                                    .font(T.sans(14, .regular))
                                    .foregroundColor(T.ink3)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 10)
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(filteredApps, id: \.bundleIdentifier) { app in
                                        AppRowView(app: app)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .background { ForgeBackdrop() }
                .navigationTitle("Apps")
                .searchable(text: $searchText, prompt: "Search Apps")
            }
        }
    }

    // MARK: - Featured Section

    private var featuredSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(featuredApps, id: \.bundleIdentifier) { app in
                    FeaturedCardView(app: app)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Data Helpers

    private var allApps: [FeedApp] {
        sourceStore.apps
    }

    private var featuredApps: [FeedApp] {
        Array(allApps.prefix(5))
    }

    private var filteredApps: [FeedApp] {
        if searchText.isEmpty {
            return Array(allApps.dropFirst(featuredApps.count))
        } else {
            return allApps.filter { app in
                let titleMatches = app.title?.localizedCaseInsensitiveContains(searchText) ?? false
                let idMatches = app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
                return titleMatches || idMatches
            }
        }
    }
}

// MARK: - Featured Card View

struct FeaturedCardView: View {
    let app: FeedApp
    @Environment(\.forgeTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FEATURED")
                .font(T.mono(11))
                .foregroundColor(T.accent)

            Text(app.title ?? app.bundleIdentifier)
                .font(T.sans(18, .bold))
                .foregroundColor(T.ink)
                .lineLimit(1)

            Text(app.description ?? "Must-have app")
                .font(T.sans(13, .regular))
                .foregroundColor(T.ink3)
                .lineLimit(1)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(T.rule2)
                    .frame(width: 300, height: 180)
                    .overlay {
                        if let iconURL = app.iconURL {
                            AsyncImage(url: iconURL) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                        }
                    }
                    .clipped()

                HStack {
                    if let iconURL = app.iconURL {
                        AsyncImage(url: iconURL) { img in
                            img.resizable().scaledToFit()
                        } placeholder: {
                            Color.gray
                        }
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                    }

                    VStack(alignment: .leading) {
                        Text(app.title ?? app.bundleIdentifier)
                            .font(T.sans(13, .semibold))
                            .foregroundColor(.white)
                        if let version = app.versions.first?.version {
                            Text(version)
                                .font(T.sans(10, .regular))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    Spacer()

                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
                .padding(12)
                .background(.ultraThinMaterial)
            }
            .cornerRadius(18)
        }
        .frame(width: 300)
    }
}

// MARK: - App Row View

struct AppRowView: View {
    let app: FeedApp
    @Environment(\.forgeTheme) private var T

    var body: some View {
        HStack(spacing: 12) {
            if let iconURL = app.iconURL {
                AsyncImage(url: iconURL) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(T.rule2)
                }
                .frame(width: 54, height: 54)
                .cornerRadius(12)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .foregroundColor(T.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.title ?? app.bundleIdentifier)
                    .font(T.sans(15, .semibold))
                    .foregroundColor(T.ink)

                Text(app.description ?? "App available for install")
                    .font(T.sans(12, .regular))
                    .foregroundColor(T.ink3)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 20))
                .foregroundColor(T.accent)
        }
        .padding(12)
        .fGlass(cornerRadius: 14)
    }
}
