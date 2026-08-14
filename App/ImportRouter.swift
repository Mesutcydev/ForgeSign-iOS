import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportRouter: ObservableObject {
    enum Destination: Equatable {
        case ipa(URL)
        case dylib(URL)
        case unsupported(URL)
    }

    @Published private(set) var pending: Destination?
    @Published var error: ForgeDiagnostic?

    func receive(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ipa", "zip": pending = .ipa(url)
        case "dylib": pending = .dylib(url)
        default:
            pending = .unsupported(url)
            error = .importFailure
        }
    }

    func consume() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
