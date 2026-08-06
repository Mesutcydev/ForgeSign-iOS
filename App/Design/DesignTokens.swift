import SwiftUI

// MARK: - Shared semantic design tokens (ported from the CodeLens design system)

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum AppRadius {
    static let control: CGFloat = 12
    static let card: CGFloat = 20
    static let panel: CGFloat = 24
}

enum AppTypography {
    static let eyebrow: Font = .caption2.weight(.semibold)
    static let secondary: Font = .subheadline
    static let body: Font = .body
    static let title: Font = .title3.weight(.semibold)
}

enum AppStroke {
    static let hairline: CGFloat = 0.5
    static let regular: CGFloat = 1
}

enum AppShadow {
    static let panelColor = Color.black.opacity(0.16)
    static let panelRadius: CGFloat = 18
    static let panelY: CGFloat = 6
}

enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.16)
    static let state = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

/// A more opaque material panel (fill + hairline stroke + soft shadow) for
/// surfaces that need to stay readable over busy content.
struct AppPanelBackground: ViewModifier {
    var cornerRadius: CGFloat = AppRadius.panel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(uiColor: .systemBackground))
                } else {
                    shape.fill(.thinMaterial)
                }
            }
            .overlay {
                shape.stroke(
                    Color.primary.opacity(0.10),
                    lineWidth: AppStroke.hairline
                )
            }
            .shadow(color: AppShadow.panelColor, radius: AppShadow.panelRadius, y: AppShadow.panelY)
    }
}

extension View {
    func appPanel(cornerRadius: CGFloat = AppRadius.panel) -> some View {
        modifier(AppPanelBackground(cornerRadius: cornerRadius))
    }

    func minimumInteractiveSize() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }
}
