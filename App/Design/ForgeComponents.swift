import SwiftUI

// MARK: - Tactile press style (from SiteAgent GlassPressStyle)

struct GlassTactileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .brightness(configuration.isPressed ? 0.045 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

// MARK: - Text primitives

/// Small monospaced caption — key text style for values & badges.
struct MonoText: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .medium
    var color: Color? = nil
    var tracking: CGFloat = 0

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Text(text)
            .font(T.mono(size, weight))
            .foregroundColor(color ?? T.ink2)
            .tracking(tracking)
    }
}

/// Uppercase section header label in ink3.
struct CaptionText: View {
    let text: String
    var color: Color? = nil

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Text(text.uppercased())
            .font(T.sans(11, .bold))
            .foregroundColor(color ?? T.ink3)
            .tracking(0.4)
    }
}

// MARK: - Buttons

/// Primary action button with colorless glass hero surface.
struct GlassPrimaryButton: View {
    let label: String
    var systemImage: String? = nil
    var action: () -> Void = {}
    var disabled: Bool = false

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(label).font(T.sans(15, .semibold))
            }
            .foregroundColor(T.isDark ? .white : T.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity)
            .glassSurface(.button)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule2, lineWidth: AppStroke.hairline)
            }
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(GlassTactileButtonStyle())
        .disabled(disabled)
    }
}

/// Secondary action button — glass surface + subtle hairline rule.
struct GlassSecondaryButton: View {
    let label: String
    var systemImage: String? = nil
    var destructive: Bool = false
    var action: () -> Void = {}

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundColor(destructive ? T.bad : T.ink)
                }
                Text(label).font(T.sans(13.5, .semibold))
                    .foregroundColor(destructive ? T.bad : T.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity)
            .glassSurface(.button)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
    }
}

// MARK: - Section & rows (grouped glass card chrome)

struct GlassSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.forgeTheme) private var T

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CaptionText(text: title)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(T.rule).frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 10)

            VStack(spacing: 0) { content() }
                .glassSurface(.card, cornerRadius: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }
}

/// 1px rule divider used between rows inside a section card.
struct GlassRowDivider: View {
    @Environment(\.forgeTheme) private var T

    var body: some View {
        Rectangle().fill(T.rule).frame(height: 1)
    }
}

/// Row inside a GlassSection.
struct GlassRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.forgeTheme) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Text(label).font(T.sans(15, .medium)).foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// A file or signing-asset selection. At accessibility sizes the value moves
/// below its label instead of squeezing both into narrow columns.
struct SigningAssetRow: View {
    let icon: String
    let label: String
    let value: String?
    var status: String? = nil
    var statusColor: Color = .secondary
    let action: () -> Void

    @Environment(\.forgeTheme) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let accessibleSize = dynamicTypeSize.isAccessibilitySize
        let layout = accessibleSize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                layout {
                    Text(label)
                        .font(T.sans(15, .medium))
                        .foregroundColor(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !accessibleSize { Spacer(minLength: 8) }
                    VStack(alignment: accessibleSize ? .leading : .trailing, spacing: 4) {
                        if let status { GlassStatusPill(text: status, color: statusColor) }
                        Text(value ?? "Choose…")
                            .font(value == nil ? T.sans(13) : T.mono(12))
                            .foregroundColor(value == nil ? T.ink3 : T.ink2)
                            .lineLimit(accessibleSize ? 2 : 1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: accessibleSize ? .infinity : 150,
                           alignment: accessibleSize ? .leading : .trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue([value ?? "not selected", status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Double-tap to choose a file.")
    }
}

struct GlassFileRow: View {
    let icon: String
    let label: String
    let file: URL?
    let action: () -> Void

    var body: some View {
        SigningAssetRow(icon: icon, label: label, value: file?.lastPathComponent, action: action)
    }
}

/// Text-input row.
struct GlassInputRow: View {
    let icon: String
    let label: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    @Environment(\.forgeTheme) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 22)
                Text(label).font(T.sans(15, .medium)).foregroundColor(T.ink)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .textFieldStyle(.plain)
            .font(T.mono(13))
            .foregroundColor(T.ink)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 170)
            .accessibilityLabel(label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// Toggle row.
struct GlassToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(T.sans(15, .medium)).foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .tint(T.controlTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Small primitives

/// Status pill — mono 9 semibold uppercase, colorless glass capsule.
struct GlassStatusPill: View {
    let text: String
    let color: Color

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Text(text.uppercased())
            .font(T.mono(9, .semibold))
            .tracking(0)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(color.opacity(T.isDark ? 0.16 : 0.12))
            }
            .overlay {
                Capsule().stroke(color.opacity(T.isDark ? 0.40 : 0.28), lineWidth: AppStroke.hairline)
            }
    }
}

/// Bordered mono tag (e.g. a bundle id or version chip).
struct GlassTag: View {
    let text: String
    var size: CGFloat = 10

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Text(text)
            .font(T.mono(size))
            .foregroundColor(T.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .glassSurface(.badge)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
    }
}
