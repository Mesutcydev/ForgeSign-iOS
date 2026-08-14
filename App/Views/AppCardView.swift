import SwiftUI

struct AppCardView: View {
    let app: FeedApp
    let onOpen: () -> Void
    @Environment(\.forgeTheme) private var T

    var body: some View {
        Button { onOpen() } label: {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: app.iconURL) { phase in
                    switch phase {
                    case .empty:
                        Color.gray.opacity(0.08)
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Color.gray.opacity(0.08)
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(height: 120)
                .clipped()
                .fGlass(cornerRadius: 12)

                Text(app.title ?? app.bundleIdentifier)
                    .font(T.sans(14))
                    .foregroundColor(T.ink)
                    .lineLimit(2)

                Text(app.developer ?? "")
                    .font(T.mono(12))
                    .foregroundColor(T.ink2)

                HStack {
                    if let v = app.versions.first?.version {
                        GlassStatusPill(text: v, color: T.accent)
                    }
                    Spacer()
                }
            }
            .padding(10)
            .fGlass(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.rule2, lineWidth: AppStroke.hairline))
        }
        .buttonStyle(.plain)
    }
}
