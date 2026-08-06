import SwiftUI

/// Technical canvas grid: drawn once with Canvas.
struct GridTexture: View {
    var spacing: CGFloat = 22
    var color: Color = .white.opacity(0.05)

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            ctx.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Ambient page canvas: backdrop content for clear Liquid Glass.
/// Features a flat system grouped background, colorless primary and secondary
/// ambient light blooms, and a technical grid overlay.
struct ForgeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            Circle()
                .fill(backgroundLightPrimary)
                .frame(width: 460, height: 460)
                .blur(radius: 105)
                .offset(x: -150, y: -260)

            Circle()
                .fill(backgroundLightSecondary)
                .frame(width: 400, height: 400)
                .blur(radius: 115)
                .offset(x: 170, y: 300)

            GridTexture(
                spacing: 22,
                color: Color.primary.opacity(colorScheme == .dark ? 0.065 : 0.045)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backgroundLightPrimary: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var backgroundLightSecondary: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }
}
