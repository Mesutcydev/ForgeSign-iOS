import SwiftUI

// MARK: - Centralized Colorless Liquid Glass system (ported from SiteAgent)

enum GlassRole: Sendable {
    case hero
    case card
    case button
    case capsule
    case icon
    case badge
    case tabBar
    case toolbarButton
    case listRow
    case composer
    case composerField

    var cornerRadius: CGFloat {
        switch self {
        case .hero: return 24
        case .card, .listRow: return 18
        case .button: return 16
        case .composer: return 30
        case .composerField: return 20
        case .capsule, .badge: return 999
        case .icon, .toolbarButton: return 14
        case .tabBar: return 30
        }
    }

    var isInteractive: Bool {
        switch self {
        case .button, .capsule, .icon, .badge, .toolbarButton, .tabBar, .composer, .composerField: return true
        case .hero, .card, .listRow: return false
        }
    }

    /// Preserve a visible optical rim on compact controls while keeping broad
    /// surfaces transparent enough for backdrop detail to read through.
    var materialOpacity: Double {
        switch self {
        case .hero, .card, .listRow: return 0.30
        case .button: return 0.34
        case .composer: return 0.72
        case .composerField: return 0.62
        case .capsule, .icon, .badge, .toolbarButton, .tabBar: return 0.52
        }
    }
}

@available(iOS 26.0, *)
private func nativeGlass(for role: GlassRole) -> Glass {
    var glass: Glass = .clear
    if role.isInteractive { glass = glass.interactive() }
    return glass
}

private struct GlassSurfaceModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if #available(iOS 26.0, *), !reduceTransparency {
            // Keep Liquid Glass out of layout measurement. A geometry-locked,
            // colorless backdrop preserves original content size while letting the
            // system render live blur, refraction, edge light and interaction.
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(
                            nativeGlass(for: role),
                            in: .rect(cornerRadius: radius)
                        )
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

// MARK: - Shape-based glass variants

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

    /// Card-style glass surface.
    func fGlass(cornerRadius: CGFloat = 18) -> some View {
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

// MARK: - Glass Container Morphing

/// Morphing container for glass elements on iOS 26+.
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

// MARK: - Working Shimmer Effect

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
