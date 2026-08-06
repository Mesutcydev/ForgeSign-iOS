import SwiftUI

// MARK: - Centralized Liquid Glass renderer
//
// Ported from the CodeLens glass design system. Every glass surface routes
// through ONE primitive so the whole app shares the same optical language:
// iOS 26 renders `.glassEffect(.clear)`; pre-26 / Reduce Transparency falls
// back to `.ultraThinMaterial` with the same silhouette.

enum GlassRole {
    case hero, card, listRow, button, capsule, icon, badge, toolbarButton

    var radius: CGFloat {
        switch self {
        case .hero: 24
        case .card, .listRow: 18
        case .button: 16
        case .capsule, .badge: 999
        case .icon, .toolbarButton: 14
        }
    }

    var interactive: Bool {
        switch self {
        case .button, .capsule, .icon, .badge, .toolbarButton: true
        default: false
        }
    }

    var materialOpacity: Double {
        switch self {
        case .hero, .card, .listRow: 0.30
        case .button: 0.34
        case .capsule, .icon, .badge, .toolbarButton: 0.52
        }
    }
}

@available(iOS 26.0, *)
private func nativeGlass(for role: GlassRole) -> Glass {
    var glass: Glass = .clear
    if role.interactive { glass = glass.interactive() }
    return glass
}

private struct GlassSurfaceModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.radius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if #available(iOS 26.0, *), !reduceTransparency {
            // Geometry-lock the optical layer so the glass' ideal bounds
            // cannot expand a flexible row or button. Only this background
            // is translucent; foreground content stays fully opaque.
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(nativeGlass(for: role), in: .rect(cornerRadius: radius))
                        .opacity(role.materialOpacity)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Apple Liquid Glass on iOS 26+. Pre-26 renders an ultra-thin material
    /// with the same light-catching silhouette. This is the single surface
    /// primitive the whole theme routes through.
    func glassSurface(
        _ role: GlassRole = .card,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(GlassSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }
}

// MARK: - Shape-based variants

extension View {
    /// Clear glass in an arbitrary insettable shape (capsule, circle, …).
    func fClearGlass<S: InsettableShape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: shape,
            role: interactive ? .button : .capsule
        ))
    }

    /// Card-style glass with a corner radius.
    func fGlass(cornerRadius: CGFloat = 10) -> some View {
        glassSurface(.card, cornerRadius: cornerRadius)
    }

    /// Capsule variant of `fGlass`.
    func fGlassCapsule() -> some View {
        modifier(ShapeGlassSurfaceModifier(shape: Capsule(), role: .capsule))
    }
}

private struct ShapeGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let role: GlassRole

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(nativeGlass(for: role), in: shape)
                        .opacity(role.materialOpacity)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Container

/// Wraps a group of glass elements so iOS can morph them as one shape during
/// transitions. No-op pre-iOS 26.
struct FGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Shimmer
// Gradient sweep that animates across a view to indicate "working". Drawn
// with `.blendMode(.softLight)` so it lights the underlying surface instead
// of recoloring it. Animates offset (not opacity) because offset animation
// is GPU-cheap and runs on the compositor.

extension View {
    func shimmer(
        isActive: Bool = true,
        duration: Double = 1.4,
        intensity: Double = 0.55
    ) -> some View {
        modifier(ShimmerModifier(isActive: isActive, duration: duration, intensity: intensity))
    }
}

private struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    let duration: Double
    let intensity: Double

    @State private var phase: CGFloat = -1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive, !reduceMotion {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let bandWidth = width * 0.65
                        LinearGradient(
                            stops: [
                                .init(color: .clear,                    location: 0.0),
                                .init(color: .white.opacity(intensity), location: 0.5),
                                .init(color: .clear,                    location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .offset(x: phase * (width + bandWidth))
                        .blendMode(.softLight)
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask(content)
            .onAppear {
                guard isActive, !reduceMotion else { return }
                withAnimation(
                    .linear(duration: duration).repeatForever(autoreverses: false)
                ) { phase = 1.0 }
            }
            .onChange(of: isActive) { nowActive in
                if nowActive, !reduceMotion {
                    phase = -1.0
                    withAnimation(
                        .linear(duration: duration).repeatForever(autoreverses: false)
                    ) { phase = 1.0 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { phase = -1.0 }
                }
            }
    }
}
