import SwiftUI

/// Ambient page canvas: a flat themed background plus three huge blurred
/// color blooms. This is the "live pixels" layer that sits under every
/// screen so clear glass has something to refract. Ported from the
/// CodeLens backdrop recipe (accent / mint / lavender, blur 38–52).
struct ForgeBackdrop: View {
    @Environment(\.forgeTheme) private var T

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                T.bg

                Circle()
                    .fill(T.accent.opacity(T.isDark ? 0.18 : 0.10))
                    .frame(width: proxy.size.width * 1.05)
                    .blur(radius: 38)
                    .offset(x: -proxy.size.width * 0.42, y: -proxy.size.height * 0.26)

                Circle()
                    .fill(Color(red: 0.42, green: 0.78, blue: 0.72)   // mint
                        .opacity(T.isDark ? 0.13 : 0.12))
                    .frame(width: proxy.size.width * 0.86)
                    .blur(radius: 46)
                    .offset(x: proxy.size.width * 0.42, y: proxy.size.height * 0.04)

                RoundedRectangle(cornerRadius: 64, style: .continuous)
                    .fill(Color(red: 0.72, green: 0.62, blue: 0.96)   // lavender
                        .opacity(T.isDark ? 0.12 : 0.10))
                    .frame(width: proxy.size.width * 1.15, height: proxy.size.height * 0.34)
                    .rotationEffect(.degrees(-18))
                    .blur(radius: 52)
                    .offset(x: proxy.size.width * 0.18, y: proxy.size.height * 0.39)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
