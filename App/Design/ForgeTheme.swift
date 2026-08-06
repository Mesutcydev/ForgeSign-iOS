import SwiftUI

/// ForgeSign glass theme — color palette and typography.
///
/// Visual language ported from the CodeLens "clear glass" design system:
/// Apple clear glass, neutral content, color reserved for state or a
/// primary action. Values match the reference light/dark palettes.
struct ForgeTheme {
    // Background layers
    let bg: Color           // page background
    let surface: Color      // cards
    let surface2: Color     // secondary surface
    let surface3: Color     // tertiary surface

    // Text ink (4 levels of hierarchy)
    let ink: Color          // primary
    let ink2: Color         // secondary
    let ink3: Color         // tertiary / labels
    let ink4: Color         // disabled / very subtle

    // Borders
    let rule: Color         // hairline
    let rule2: Color        // stronger

    // Brand
    let accent: Color
    let accentSoft: Color
    let accentSofter: Color

    // Semantic
    let good: Color
    let warn: Color
    let bad: Color

    // Spacing
    let pad: CGFloat
    let gap: CGFloat

    let isDark: Bool

    // Accent gradient anchors (primary CTA, active states)
    let accentHi: Color
    let accentDeep: Color
    let accentStrong: Color
}

extension ForgeTheme {
    static let light = ForgeTheme(
        bg:        Color(red: 0.968, green: 0.976, blue: 0.992),  // airy pearl canvas
        surface:   Color.white.opacity(0.26),
        surface2:  Color.white.opacity(0.18),
        surface3:  Color.white.opacity(0.10),
        ink:       Color(red: 0.110, green: 0.110, blue: 0.118),  // #1C1C1E label
        ink2:      Color(red: 0.427, green: 0.427, blue: 0.447),  // #6D6D72 secondary
        ink3:      Color(red: 0.557, green: 0.557, blue: 0.576),  // #8E8E93 tertiary
        ink4:      Color(red: 0.780, green: 0.780, blue: 0.800),  // #C7C7CC quaternary
        rule:      Color.black.opacity(0.10),
        rule2:     Color.black.opacity(0.18),
        accent:    Color(red: 0.000, green: 0.478, blue: 1.000),
        accentSoft:   Color(red: 0.000, green: 0.478, blue: 1.000).opacity(0.10),
        accentSofter: Color(red: 0.000, green: 0.478, blue: 1.000).opacity(0.06),
        good:      Color(red: 0.133, green: 0.545, blue: 0.302),
        warn:      Color(red: 0.690, green: 0.424, blue: 0.047),
        bad:       Color(red: 0.784, green: 0.118, blue: 0.196),
        pad: 16, gap: 10,
        isDark: false,
        accentHi:     Color(red: 0.200, green: 0.560, blue: 1.000),
        accentDeep:   Color(red: 0.000, green: 0.330, blue: 0.780),
        accentStrong: Color(red: 0.000, green: 0.400, blue: 0.900)
    )

    static let dark = ForgeTheme(
        // Lift the canvas above black so clear glass reads as smoked crystal
        bg:        Color(red: 0.140, green: 0.155, blue: 0.190),
        surface:   Color.white.opacity(0.13),
        surface2:  Color.white.opacity(0.18),
        surface3:  Color.white.opacity(0.08),
        ink:       Color(red: 0.929, green: 0.929, blue: 0.937),
        ink2:      Color(red: 0.706, green: 0.706, blue: 0.729),
        ink3:      Color(red: 0.510, green: 0.510, blue: 0.533),
        ink4:      Color(red: 0.337, green: 0.337, blue: 0.357),
        rule:      Color.white.opacity(0.15),
        rule2:     Color.white.opacity(0.25),
        accent:    Color(red: 0.220, green: 0.600, blue: 1.000),
        accentSoft:   Color(red: 0.220, green: 0.600, blue: 1.000).opacity(0.16),
        accentSofter: Color(red: 0.220, green: 0.600, blue: 1.000).opacity(0.09),
        good:      Color(red: 0.392, green: 0.784, blue: 0.533),
        warn:      Color(red: 0.898, green: 0.643, blue: 0.263),
        bad:       Color(red: 0.902, green: 0.404, blue: 0.431),
        pad: 16, gap: 10,
        isDark: true,
        accentHi:     Color(red: 0.360, green: 0.660, blue: 1.000),
        accentDeep:   Color(red: 0.040, green: 0.450, blue: 0.920),
        accentStrong: Color(red: 0.220, green: 0.600, blue: 1.000)
    )

    var accentStrongSoft: Color { accentStrong.opacity(isDark ? 0.18 : 0.12) }

    /// Quiet supporting glyph color.
    var accent2: Color {
        isDark ? Color(red: 0.620, green: 0.650, blue: 0.700)
               : Color(red: 0.430, green: 0.460, blue: 0.520)
    }
}

// MARK: - Typography

extension ForgeTheme {
    /// Display / sans body.
    func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced — pervasive in this design language (values, badges, labels).
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Environment wiring

private struct ForgeThemeKey: EnvironmentKey {
    static let defaultValue: ForgeTheme = .light
}

extension EnvironmentValues {
    var forgeTheme: ForgeTheme {
        get { self[ForgeThemeKey.self] }
        set { self[ForgeThemeKey.self] = newValue }
    }
}

extension View {
    func forgeTheme(_ theme: ForgeTheme) -> some View {
        self.environment(\.forgeTheme, theme)
    }

    /// Allows up to `.accessibility2` so the design doesn't blow up.
    func forgeScaledType() -> some View {
        self.dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
