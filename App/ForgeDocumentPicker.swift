import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Imports a picked file into the app's container (a copy), then each caller
/// validates the extension in its callback.
///
/// Use a broad filter so Files can supply items with provider-specific types.
struct ForgeDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true is import mode — the system hands us a copy in our own
        // container, so no security-scoped access dance is required.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let isPresented: Binding<Bool>
        private let onPick: (URL) -> Void

        init(isPresented: Binding<Bool>, onPick: @escaping (URL) -> Void) {
            self.isPresented = isPresented
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
            dismissPicker()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismissPicker()
        }

        private func dismissPicker() {
            Task { @MainActor in isPresented.wrappedValue = false }
        }
    }
}
