import SwiftUI

// MARK: - Color extensions for Adaptive & Hex parsing (from SiteAgent)

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        guard !s.isEmpty, Scanner(string: s).scanHexInt64(&v) else {
            self = .clear
            return
        }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue:  Double(v & 0xFF) / 255
        )
    }

    init(hex: UInt32, alpha: Double = 1) {
        self = Color(hex: String(format: "%06X", hex)).opacity(alpha)
    }

    init(light: String, dark: String) {
        self = Color(UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

/// ForgeSign Colorless Glass theme — light and dark palettes.
///
/// Ported from SiteAgent's colorless glass design system: untinted clear
/// Liquid Glass surfaces over an ambient backdrop, neutral high-contrast ink,
/// and adaptive colorless control tints in both light and dark modes.
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
    let ink4: Color         // disabled / subtle

    // Borders
    let rule: Color         // hairline
    let rule2: Color        // stronger

    // Brand / Neutral Accent
    let accent: Color
    let accentSoft: Color
    let accentSofter: Color

    // Semantic
    let good: Color
    let warn: Color
    let bad: Color

    // Layout Spacing
    let pad: CGFloat
    let gap: CGFloat

    let isDark: Bool

    // Accent gradient anchors
    let accentHi: Color
    let accentDeep: Color
    let accentStrong: Color
}

extension ForgeTheme {
    /// Colorless Glass Light Theme
    static let light = ForgeTheme(
        bg:        Color(.systemGroupedBackground),
        surface:   Color.white.opacity(0.26),
        surface2:  Color.white.opacity(0.18),
        surface3:  Color.white.opacity(0.10),
        ink:       Color(red: 0.110, green: 0.110, blue: 0.118),  // #1C1C1E
        ink2:      Color(red: 0.427, green: 0.427, blue: 0.447),  // #6D6D72
        ink3:      Color(red: 0.557, green: 0.557, blue: 0.576),  // #8E8E93
        ink4:      Color(red: 0.780, green: 0.780, blue: 0.800),  // #C7C7CC
        rule:      Color.black.opacity(0.08),
        rule2:     Color.black.opacity(0.16),
        accent:    Color(hex: "4A5058"),
        accentSoft:   Color(hex: "4A5058").opacity(0.10),
        accentSofter: Color(hex: "4A5058").opacity(0.06),
        good:      Color(red: 0.133, green: 0.545, blue: 0.302),
        warn:      Color(red: 0.690, green: 0.424, blue: 0.047),
        bad:       Color(red: 0.784, green: 0.118, blue: 0.196),
        pad: 18, gap: 14,
        isDark: false,
        accentHi:     Color(hex: "626B76"),
        accentDeep:   Color(hex: "343940"),
        accentStrong: Color(hex: "4A5058")
    )

    /// Colorless Glass Dark Theme
    static let dark = ForgeTheme(
        bg:        Color(.systemGroupedBackground),
        surface:   Color.white.opacity(0.13),
        surface2:  Color.white.opacity(0.18),
        surface3:  Color.white.opacity(0.08),
        ink:       Color(red: 0.929, green: 0.929, blue: 0.937),
        ink2:      Color(red: 0.706, green: 0.706, blue: 0.729),
        ink3:      Color(red: 0.510, green: 0.510, blue: 0.533),
        ink4:      Color(red: 0.337, green: 0.337, blue: 0.357),
        rule:      Color.white.opacity(0.12),
        rule2:     Color.white.opacity(0.22),
        accent:    Color(hex: "D7DCE3"),
        accentSoft:   Color(hex: "D7DCE3").opacity(0.16),
        accentSofter: Color(hex: "D7DCE3").opacity(0.09),
        good:      Color(red: 0.392, green: 0.784, blue: 0.533),
        warn:      Color(red: 0.898, green: 0.643, blue: 0.263),
        bad:       Color(red: 0.902, green: 0.404, blue: 0.431),
        pad: 18, gap: 14,
        isDark: true,
        accentHi:     Color(hex: "E2E7ED"),
        accentDeep:   Color(hex: "8A939E"),
        accentStrong: Color(hex: "D7DCE3")
    )

    /// Tint for control icons & interactive elements in colorless mode.
    var controlTint: Color {
        isDark ? Color(hex: "D7DCE3") : Color(hex: "4A5058")
    }

    var accentStrongSoft: Color { accentStrong.opacity(isDark ? 0.18 : 0.12) }

    /// Quiet supporting glyph color.
    var accent2: Color {
        isDark ? Color(hex: "D7DCE3") : Color(hex: "4A5058")
    }
}

// MARK: - Typography

extension ForgeTheme {
    /// Display / SF Rounded heading.
    func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Sans body typography.
    func sans(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced — pervasive for values, badges, and labels.
    func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
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

    func forgeScaledType() -> some View {
        self.dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
