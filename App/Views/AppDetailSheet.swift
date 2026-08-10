import SwiftUI

struct AppDetailSheet: View {
    let app: FeedApp
    var onInstall: (FeedVersion) -> Void
    @Environment(\.forgeTheme) private var T
    @EnvironmentObject private var certStore: CertificateStore
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var showCertSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    AsyncImage(url: app.iconURL) { phase in
                        switch phase {
                        case .empty:
                            Color.gray.opacity(0.08)
                        case .success(let img):
                            img.resizable().scaledToFit()
                        case .failure:
                            Color.gray.opacity(0.08)
                        @unknown default:
                            Color.clear
                        }
                    }
                    .frame(width: 80, height: 80)
                    .fGlass(cornerRadius: 16)

                    VStack(alignment: .leading) {
                        Text(app.title ?? app.bundleIdentifier)
                            .font(T.display(20))
                            .foregroundColor(T.ink)
                        Text(app.developer ?? "")
                            .font(T.mono(12))
                            .foregroundColor(T.ink2)
                    }
                    Spacer()
                }

                GlassSection("About") {
                    Text(app.description ?? "No description available.")
                        .font(T.mono(13))
                        .foregroundColor(T.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GlassSection("Versions") {
                    VStack(spacing: 8) {
                        ForEach(app.versions, id: \.version) { v in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(v.version).font(T.sans(13)).foregroundColor(T.ink)
                                    Text(ByteCountFormatter.string(fromByteCount: v.size ?? 0, countStyle: .file))
                                        .font(T.mono(11)).foregroundColor(T.ink3)
                                }
                                Spacer()
                                GlassPrimaryButton(label: "Install") {
                                    onInstall(v)
                                    dismiss()
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle(app.title ?? "App")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCertSheet = true
                    } label: {
                        Text("Certificates")
                    }
                    .buttonStyle(GlassTactileButtonStyle())
                }
            }
            .sheet(isPresented: $showCertSheet) {
                CertificatesSheet()
            }
        }
    }
}
