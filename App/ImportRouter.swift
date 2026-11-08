import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportRouter: ObservableObject {
    enum Destination: Equatable {
        case ipa(URL)
        case dylib(URL)
        /// A Library refresh: re-sign a kept original under its original name
        /// and with the bundle ID the installed app has, so it upgrades in place.
        case refresh(URL, bundleID: String, name: String)
    }

    @Published private(set) var pending: Destination?

    func receive(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ipa", "zip": pending = .ipa(url)
        case "dylib": pending = .dylib(url)
        default: break
        // An unrelated URL must not drop a valid pending import that the
        // Sign tab has not consumed yet.
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
