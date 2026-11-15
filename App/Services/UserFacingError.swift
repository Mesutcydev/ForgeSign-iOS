import Foundation

/// The text a user sees for an error. System errors such as
/// "NSPOSIXErrorDomain error 48" are replaced with what they mean (audit N11).
enum UserFacingError {
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EADDRINUSE):
                return "Another install is already using the local port. Close other installs and retry."
            case Int(ECONNREFUSED), Int(ECONNRESET), Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH):
                return "The connection failed. Check the network and retry."
            case Int(ENOSPC):
                return "The device is out of storage. Free some space and retry."
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            return "There is no internet connection. Connect and retry."
        }
        return error.localizedDescription
    }
}
