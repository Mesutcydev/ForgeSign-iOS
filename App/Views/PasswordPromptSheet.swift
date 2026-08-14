import SwiftUI

struct PasswordPromptSheet: View {
    let cert: CertificateRecord
    var onComplete: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T

    @State private var password: String = ""
    @State private var remember: Bool = true
    @State private var showInvalid = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GlassSection("Certificate") {
                    HStack {
                        Image(systemName: "key.fill").foregroundColor(T.accent2)
                        VStack(alignment: .leading) {
                            Text(cert.displayName).font(T.sans(14)).foregroundColor(T.ink)
                            if let cn = cert.commonName { Text(cn).font(T.mono(11)).foregroundColor(T.ink2) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                }

                GlassSection("P12 password") {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(12)
                    Toggle("Remember password", isOn: $remember)
                        .padding(.horizontal, 12)
                }

                if showInvalid {
                    Text("Password is required to proceed.").font(T.mono(12)).foregroundColor(T.bad)
                }

                Spacer()

                HStack {
                    GlassSecondaryButton(label: "Cancel") {
                        dismiss()
                    }
                    GlassPrimaryButton(label: "Continue") {
                        if password.isEmpty {
                            showInvalid = true
                            return
                        }
                        onComplete(password, remember)
                        dismiss()
                    }
                }
                .padding(.bottom, 12)
            }
            .padding()
            .navigationTitle("Enter P12 Password")
        }
    }
}
