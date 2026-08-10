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
                        
                        // 1. Featured Carousel (الكروت العريضة فوق)
                        if !featuredApps.isEmpty {
                            featuredSection
                        }

                        // 2. Apps List (قائمة التطبيقات المفردة)
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
                .navigationTitle("التطبيق")
                .searchable(text: $searchText, prompt: "البحث في التطبيقات")
            }
        }
    }

    // MARK: - Featured Section (الكروت فوق)

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

    // MARK: - Filtering Data

    private var allApps: [StoreApp] {
        repoStore.apps
    }

    private var featuredApps: [StoreApp] {
        Array(allApps.prefix(5)) // يأخذ أول 5 تطبيقات يعرضها ككروت عريضة فوق
    }

    private var filteredApps: [StoreApp] {
        if searchText.isEmpty {
            return Array(allApps.dropFirst(5)) // باقي التطبيقات بالقائمة
        } else {
            return allApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

// MARK: - Featured Card Component (كارت الهيدر)

struct FeaturedCardView: View {
    let app: StoreApp
    @Environment(\.forgeTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("يحدث الآن")
                .font(T.mono(11))
                .foregroundColor(T.accent)

            Text(app.name)
                .font(T.sans(18, .bold))
                .foregroundColor(T.ink)
                .lineLimit(1)

            Text(app.subtitle ?? "تطبيق مميز ينصح به")
                .font(T.sans(13, .regular))
                .foregroundColor(T.ink3)
                .lineLimit(1)

            ZStack(alignment: .bottom) {
                // صورة الخلفية أو معاينة الكارت
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

                // شريط بروفايل التطبيق السفلي المدمج بالشرائح
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
                        Text(app.subtitle ?? "")
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

// MARK: - App Row Component (سطر التطبيق العادي)

struct AppRowView: View {
    let app: StoreApp
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

                Text(app.subtitle ?? "تحديث جديد متوفر")
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
