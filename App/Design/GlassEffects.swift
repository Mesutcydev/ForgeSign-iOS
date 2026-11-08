import SwiftUI

/// Shared colorless Liquid Glass surfaces, preserving the original optical
/// weight across cards and compact controls.
enum GlassRole: Sendable {
    case card, button, capsule, badge

    var cornerRadius: CGFloat {
        switch self {
        case .card: return 18
        case .button: return 16
        case .capsule, .badge: return 999
        }
    }

    var isInteractive: Bool { self != .card }

    var materialOpacity: Double {
        switch self {
        case .card: 0.30
        case .button: 0.34
        case .capsule, .badge: 0.52
        }
    }
}

private struct ShapeGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let role: GlassRole

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            } else if #available(iOS 26.0, *) {
                // Glass remains behind the content and outside layout
                // measurement. Only its optical layer receives opacity.
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(nativeGlass, in: shape)
                        .opacity(contrast == .increased ? 1 : role.materialOpacity)
                }
            } else if contrast == .increased {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
    }

    @available(iOS 26.0, *)
    private var nativeGlass: Glass {
        var glass: Glass = contrast == .increased ? .regular : .clear
        if role.isInteractive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func glassSurface(_ role: GlassRole = .card, cornerRadius: CGFloat? = nil) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius ?? role.cornerRadius, style: .continuous),
            role: role
        ))
    }

    /// Keeps existing shape-based call sites on the shared surface system.
    func fClearGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(ShapeGlassSurfaceModifier(shape: shape, role: interactive ? .button : .capsule))
    }

    func fGlass(cornerRadius: CGFloat = 18) -> some View {
        glassSurface(.card, cornerRadius: cornerRadius)
    }
}
