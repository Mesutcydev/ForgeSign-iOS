import SwiftUI

// MARK: - Stylized Glass Forge Anvil Shape

struct AnvilShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Top table and horn
        path.move(to: CGPoint(x: w * 0.12, y: h * 0.32))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.32, y: h * 0.36),
            control: CGPoint(x: w * 0.20, y: h * 0.36)
        )
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.36)) // Table top
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.44)) // Step down

        // Right waist curve
        path.addQuadCurve(
            to: CGPoint(x: w * 0.64, y: h * 0.62),
            control: CGPoint(x: w * 0.72, y: h * 0.50)
        )

        // Right foot base
        path.addQuadCurve(
            to: CGPoint(x: w * 0.82, y: h * 0.82),
            control: CGPoint(x: w * 0.74, y: h * 0.72)
        )
        path.addLine(to: CGPoint(x: w * 0.82, y: h * 0.88))
        path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.88)) // Bottom base
        path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.82))

        // Left foot base
        path.addQuadCurve(
            to: CGPoint(x: w * 0.36, y: h * 0.62),
            control: CGPoint(x: w * 0.26, y: h * 0.72)
        )

        // Left waist to horn underside
        path.addQuadCurve(
            to: CGPoint(x: w * 0.12, y: h * 0.32),
            control: CGPoint(x: w * 0.20, y: h * 0.44)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Transparent Glass Forge Logo Component

/// Transparent Liquid Glass Forge logo — features a custom glass anvil shape with
/// a rising spark motif, mounted over Apple Liquid Glass.
struct ForgeGlassLogoView: View {
    var size: CGFloat = 68

    @Environment(\.forgeTheme) private var T

    var body: some View {
        ZStack {
            // Colorless Glass plate
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .glassSurface(.hero, cornerRadius: size * 0.28)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(T.rule2, lineWidth: AppStroke.hairline)
                }

            // Glass Forge Icon (Anvil + Sparkle)
            ZStack {
                AnvilShape()
                    .fill(T.ink.opacity(T.isDark ? 0.14 : 0.08))
                    .overlay {
                        AnvilShape()
                            .stroke(T.ink.opacity(T.isDark ? 0.85 : 0.75), lineWidth: 1.5)
                    }

                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundColor(T.controlTint)
                    .offset(x: size * 0.10, y: -size * 0.18)
            }
            .frame(width: size * 0.58, height: size * 0.58)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(T.isDark ? 0.25 : 0.08), radius: 10, y: 4)
    }
}
