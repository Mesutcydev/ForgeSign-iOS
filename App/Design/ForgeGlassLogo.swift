import SwiftUI

/// Homepage / Library header mark — the 1.1.1 "signature" glass tile
/// (SF Symbol `signature` on colorless Liquid Glass). Matches AppIcon.
struct ForgeGlassLogoView: View {
    var size: CGFloat = 60

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Image(systemName: "signature")
            .font(.system(size: size * 0.40, weight: .medium))
            .foregroundColor(T.accentStrong)
            .frame(width: size, height: size)
            .fClearGlass(in: RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
            .accessibilityLabel("ForgeSign")
    }
}
