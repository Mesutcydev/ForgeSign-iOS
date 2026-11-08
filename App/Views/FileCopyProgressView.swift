import SwiftUI

struct FileCopyProgressView: View {
    let title: String
    let progress: TransferProgress?
    let cancel: () -> Void
    @Environment(\.forgeTheme) private var T

    var body: some View {
        GlassSection(title) {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: progress?.fraction)
                    .tint(T.accent)
                    .accessibilityLabel(title)
                Text(progress?.description ?? "Preparing…")
                    .font(T.mono(12))
                    .foregroundStyle(T.ink2)
                Button("Cancel copy", role: .cancel, action: cancel)
                    .font(T.sans(13, .semibold))
                    .frame(minHeight: 44)
            }
            .padding(16)
        }
    }
}
