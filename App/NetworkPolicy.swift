import Foundation

enum NetworkPolicy {
    private final class HTTPSRedirectValidator: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(validatedRedirect(request))
        }
    }

    static func makeValidatedSession() -> URLSession {
        URLSession(configuration: .ephemeral,
                   delegate: HTTPSRedirectValidator(),
                   delegateQueue: nil)
    }

    static func validatedRedirect(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, validateHTTPS(url) else { return nil }
        return request
    }

    static func validateHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else { return false }
        let blockedHosts = ["localhost", "127.0.0.1", "::1"]
        return !blockedHosts.contains(host.lowercased())
    }

    static func manifestIsValid(_ data: Data, packageURL: String, bundleID: String, version: String) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let items = root["items"] as? [[String: Any]],
              items.count == 1,
              let first = items.first,
              let assets = first["assets"] as? [[String: Any]],
              assets.filter({ ($0["kind"] as? String) == "software-package" }).count == 1,
              let package = assets.first(where: { ($0["kind"] as? String) == "software-package" }),
              let url = package["url"] as? String,
              url == packageURL else { return false }
        guard let metadata = first["metadata"] as? [String: Any] else { return false }
        guard (metadata["bundle-identifier"] as? String) == bundleID else { return false }
        if !version.isEmpty {
            return (metadata["bundle-version"] as? String) == version
        }
        return true
    }
}
