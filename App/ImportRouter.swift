import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportRouter: ObservableObject {
    enum Destination: Equatable {
        case ipa(URL)
        case dylib(URL)
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

    func consume() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
