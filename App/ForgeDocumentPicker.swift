import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Imports a picked file into the app's container (a copy), then each caller
/// validates the extension in its callback.
///
/// The type filter here is deliberately maximal (`.item` = every item). The
/// "picker opens but nothing is selectable" symptom on sideloaded builds is
/// NOT caused by this filter — even `.item`/`.data` (everything) shows it, and
/// apps *signed by* ForgeSign hit the same thing without ever using this view.
/// That points at the entitlements applied via the provisioning profile, not
/// the picker. Keep this simple; do not reintroduce custom UTI strings or the
/// deprecated `documentTypes:in:` initializer (they only add fragility).
struct ForgeDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
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
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
