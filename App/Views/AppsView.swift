import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var repoStore: RepositoryStore
    @Environment(\.forgeTheme) private var T

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        
                        if !featuredApps.isEmpty {
                            featuredSection
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Must-Have Apps")
                                .font(T.sans(20, .bold))
                                .foregroundColor(T.ink)
                                .padding(.horizontal, 16)

                            LazyVStack(spacing: 12) {
                                ForEach(filteredApps) { app in
                                    AppRowView(app: app)
                                }
                            }
                            .padding(.horizontal, 16)
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

    private var featuredSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(featuredApps) { app in
                    FeaturedCardView(app: app)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var allApps: [SourceApp] {
        repoStore.allApps
    }

    private var featuredApps: [SourceApp] {
        Array(allApps.prefix(5))
    }

    private var filteredApps: [SourceApp] {
        if searchText.isEmpty {
            return Array(allApps.dropFirst(5))
        } else {
            return allApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

struct FeaturedCardView: View {
    let app: SourceApp
    @Environment(\.forgeTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FEATURED")
                .font(T.mono(11))
                .foregroundColor(T.accent)

            Text(app.name)
                .font(T.sans(18, .bold))
                .foregroundColor(T.ink)
                .lineLimit(1)

            Text(app.localizedDescription ?? "Must-have app")
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
                        Text(app.name)
                            .font(T.sans(13, .semibold))
                            .foregroundColor(.white)
                        Text(app.version ?? "")
                            .font(T.sans(10, .regular))
                            .foregroundColor(.white.opacity(0.8))
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

struct AppRowView: View {
    let app: SourceApp
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
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(T.sans(15, .semibold))
                    .foregroundColor(T.ink)

                Text(app.localizedDescription ?? "App available for install")
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
