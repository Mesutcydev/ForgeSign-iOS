import SwiftUI

/// Every sign attempt on this device with the signing engine's output and the
/// reason an attempt failed. Copy or share it when reporting a problem.
struct SigningLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T
    @State private var text = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "The signing log is empty. Each sign attempt on this device is recorded here." : text)
                    .font(T.mono(11))
                    .foregroundColor(text.isEmpty ? T.ink3 : T.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background { ForgeBackdrop() }
            .navigationTitle("Signing Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy log")
                    .disabled(text.isEmpty)

                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share log")
                    .disabled(text.isEmpty)

                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear log")
                    .disabled(text.isEmpty)
                }
            }
            .confirmationDialog("Clear the signing log?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    ForgeLog.clear()
                    text = ForgeLog.read()
                }
            } message: {
                Text("This removes every recorded sign attempt from this device.")
            }
            .onAppear { text = ForgeLog.read() }
        }
    }
}
