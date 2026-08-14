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
        // public.data is the concrete catch-all document type. public.item is
        // abstract and can leave visible provider items disabled on iOS.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
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
