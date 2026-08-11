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
                        
                        // 1. Featured Section
                        featuredSection

                        // 2. Apps Section
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Must-Have Apps")
                                .font(T.sans(20, .bold))
                                .foregroundColor(T.ink)
                                .padding(.horizontal, 16)

                            LazyVStack(spacing: 12) {
                                ForEach(displayedApps, id: \.name) { app in
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
                ForEach(displayedApps.prefix(3), id: \.name) { app in
                    FeaturedCardView(app: app)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // جلب التطبيقات بمرونة ممتازة تجنباً لأي تعارض في الأسماء
    private var displayedApps: [DisplayApp] {
        let sources = repoStore.sources
        var list: [DisplayApp] = []
        for src in sources {
            for app in src.apps {
                list.append(DisplayApp(name: app.name,
                                       desc: app.localizedDescription ?? "Available for installation",
                                       iconURL: app.iconURL,
                                       version: app.version))
            }
        }
        if !searchText.isEmpty {
            return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return list
    }
}

// نموذج مستقل ومحلي للواجهة يمنع أي Build Error مستقبلاً
struct DisplayApp {
    let name: String
    let desc: String
    let iconURL: URL?
    let version: String?
}

struct FeaturedCardView: View {
    let app: DisplayApp
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

            Text(app.desc)
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
                        if let ver = app.version {
                            Text(ver)
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

struct AppRowView: View {
    let app: DisplayApp
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
                Text(app.name)
                    .font(T.sans(15, .semibold))
                    .foregroundColor(T.ink)

                Text(app.desc)
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
