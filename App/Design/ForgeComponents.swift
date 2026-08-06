import SwiftUI

// MARK: - Tactile press (the signature button feel)

struct GlassTactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Text primitives

/// Small monospaced caption — the workhorse text style of the design.
struct MonoText: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
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

/// Uppercase sans-bold eyebrow label (e.g. "INPUT", "OPTIONS") in ink3.
struct CaptionText: View {
    let text: String
    var color: Color? = nil

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Text(text.uppercased())
            .font(T.sans(11, .bold))
            .foregroundColor(color ?? T.ink3)
            .tracking(0)
    }
}

// MARK: - Buttons

/// Primary action — 50pt tall, accent hero gradient, white sans 15 medium.
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
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [T.accentHi, T.accentStrong],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            .shadow(color: T.accent.opacity(0.28), radius: 8, y: 2)
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(GlassTactileButtonStyle())
        .disabled(disabled)
    }
}

/// Secondary action — 44pt tall, surface glass + hairline rule, sans 13.5.
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
                Text(label).font(T.sans(13.5))
                    .foregroundColor(destructive ? T.bad : T.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .fClearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                Rectangle().fill(T.rule).frame(height: 1)   // hairline extends right
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) { content() }
                .fGlass(cornerRadius: 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }
}

/// 1px rule divider used between rows inside a section card.
struct GlassRowDivider: View {
    @Environment(\.forgeTheme) private var T

    var body: some View {
        Rectangle().fill(T.rule).frame(height: 1)
    }
}

/// One row inside a GlassSection — label sans 15 in ink, trailing content.
struct GlassRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.forgeTheme) private var T

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(T.sans(15)).foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Tappable file-picker row — quiet icon, label, chosen filename in mono.
struct GlassFileRow: View {
    let icon: String
    let label: String
    let file: URL?
    let action: () -> Void

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 22)
                Text(label).font(T.sans(15)).foregroundColor(T.ink)
                Spacer(minLength: 8)
                Text(file?.lastPathComponent ?? "Choose…")
                    .font(file == nil ? T.sans(13) : T.mono(12))
                    .foregroundColor(file == nil ? T.ink3 : T.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.ink4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }
}

/// Text-input row — quiet icon, label, trailing plain field.
struct GlassInputRow: View {
    let icon: String
    let label: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    @Environment(\.forgeTheme) private var T

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(T.accent2)
                .frame(width: 22)
            Text(label).font(T.sans(15)).foregroundColor(T.ink)
            Spacer(minLength: 8)
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
            .foregroundColor(T.ink2)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 170)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Toggle row — label plus the custom 32×18 glass toggle.
struct GlassToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    @Environment(\.forgeTheme) private var T

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(T.sans(15)).foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            GlassToggle(isOn: $isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Custom 32×18 toggle, spring-animated.
struct GlassToggle: View {
    @Binding var isOn: Bool

    @Environment(\.forgeTheme) private var T

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? T.accent : T.ink4.opacity(0.5))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Small primitives

/// Status pill — mono 9 semibold uppercase, tinted capsule.
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
            .fClearGlass(in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
    }
}
