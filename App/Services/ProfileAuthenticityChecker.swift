import Foundation

enum ProfileAuthenticityChecker {
    static func isAuthentic(_ url: URL) -> Bool {
        #if FORGE_BRIDGE
        var buffer = [CChar](repeating: 0, count: 256)
        return forgesign_profile_info(url.path, &buffer, Int32(buffer.count)) == 0
        #else
        return false
        #endif
    }
}
