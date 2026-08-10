import SwiftUI

struct DylibInjectionSection: View {
    @Binding var dylibURL: URL?
    @Binding var injectIntoExtensions: Bool
    let chooseDylib: () -> Void
    let removeDylib: () -> Void

    @Environment(\.forgeTheme) private var T

    var body: some View {
        GlassSection("Dylib injection") {
            GlassFileRow(icon: "shippingbox.fill", label: "Dylib (.dylib)", file: dylibURL) {
                chooseDylib()
            }

            if dylibURL != nil {
                GlassRowDivider()

                GlassToggleRow(label: "Inject into app extensions", isOn: $injectIntoExtensions)

                GlassRowDivider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(T.accent2)
                    Text("ForgeSign copies the dylib into a disposable IPA, adds its load command, then sends that IPA through the existing signer. Your original IPA is unchanged.")
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                GlassRowDivider()

                Button(action: removeDylib) {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13))
                            .foregroundColor(T.bad)
                        Text("Remove dylib")
                            .font(T.sans(13.5, .semibold))
                            .foregroundColor(T.bad)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(GlassTactileButtonStyle())
            }
        }
    }
}
