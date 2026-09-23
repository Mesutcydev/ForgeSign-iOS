import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportRouter: ObservableObject {
    enum Destination: Equatable {
        case ipa(URL)
        case dylib(URL)
        case pairingFile(URL)
    }

    @Published private(set) var pending: Destination?
    /// Set when the pairing card should announce what it imported.
    @Published var pairingImportMessage: String?

    func receive(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ipa", "zip": pending = .ipa(url)
        case "dylib": pending = .dylib(url)
        case "mobiledevicepairing":
            // Sent via share sheet / "Open in ForgeSign". The pairing card picks
            // this up; if it is not mounted the file is still importable from
            // the card's own importer.
            pending = .pairingFile(url)
        case "plist":
            // A plist is most often a pairing record (idevice pair / AltStore),
            // but it can also be a provisioning-profile sidecar; the pairing
            // parser rejects non-records, so route it there.
            pending = .pairingFile(url)
        default:
            pending = nil
        }
    }

    func consume() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
