import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportRouter: ObservableObject {
    enum Destination: Equatable {
        case ipa(URL)
        case dylib(URL)
        case pairingFile(URL)
        /// A Library refresh: re-sign a kept original under its original name
        /// and with the bundle ID the installed app has, so it upgrades in place.
        case refresh(URL, bundleID: String, name: String)
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

    /// Library refresh entry point. Unlike `receive(_:)`, it carries the signed
    /// bundle ID and original file name, which the kept copy no longer has.
    func receiveRefresh(_ url: URL, bundleID: String, name: String) {
        pending = .refresh(url, bundleID: bundleID, name: name)
    }

    func consume() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
