import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Imports a file into the app's container instead of opening it in place.
///
/// SwiftUI's fileImporter filters by UTI. On sideloaded devices, Files
/// providers can expose an IPA, dylib, or provisioning profile with a UTI that
/// does not match a dynamic extension type; the item is shown but disabled.
/// An unfiltered import-mode picker keeps the item selectable, while each
/// caller validates its expected extension after the callback.
struct ForgeDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Use the explicit import mode. The modern opening initializer can
        // still route through in-place document handling on re-signed apps,
        // leaving visible provider items disabled. Import mode always requests
        // a copy and matches the behavior required by this app.
        let picker = UIDocumentPickerViewController(
            documentTypes: [
                UTType.data.identifier,
                UTType.zip.identifier,
                UTType.pkcs12.identifier,
                "com.forgesign.ipa",
                "com.forgesign.dylib",
                "com.forgesign.mobileprovision",
                "com.forgesign.p12"
            ],
            in: .import
        )
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
