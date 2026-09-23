import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum AnisetteSource: String, Equatable, Sendable {
    case thisDevice = "This iPhone"
    case altServer = "AltServer"
    case altServerHost = "Anisette server on the AltServer Mac"
    case httpServer = "Anisette server"
    case remoteServer = "Remote anisette server"
}

enum AnisettePayload {
    static let defaultRoutingInfo = "17106176"
    private static let compatibleXcodeBuild = "25183.54.10"

    // Apple currently expects the client-info, macOS version, and Xcode
    // version to describe one coherent client. Older AltServer/anisette
    // servers can still return the Xcode 11/macOS 13 identity, which iOS 27
    // rejects during the GrandSlam handshake.
    static let compatibilityClientDescription =
        "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>"

    /// AltServer knows the actual Mac model and OS build. Keep those values
    /// together and update only its obsolete Xcode identity. A legacy server
    /// reporting an older macOS cannot represent this Xcode, so use the known
    /// coherent fallback in that case.
    static func clientDescription(forAltServerData raw: [String: String]) -> String {
        guard let description = firstValue(in: raw, keys: "deviceDescription", "X-MMe-Client-Info"),
              let osRange = description.range(of: #"^<[^<>]+> <macOS;(\d+)(?:\.[^;<>]+)?;[^<>]+> <com\.apple\.AuthKit/1 \(com\.apple\.dt\.Xcode/[0-9.]+\)>$"#,
                                                  options: .regularExpression),
              osRange.lowerBound == description.startIndex,
              let versionRange = description.range(of: #"(?<=<macOS;)\d+"#, options: .regularExpression),
              let majorVersion = Int(description[versionRange]), majorVersion >= 26,
              let xcodeRange = description.range(of: #"(?<=com\.apple\.dt\.Xcode/)[0-9.]+"#,
                                                      options: .regularExpression) else {
            return compatibilityClientDescription
        }
        var updated = description
        updated.replaceSubrange(xcodeRange, with: compatibleXcodeBuild)
        return updated
    }

    static func json(from raw: [String: String], clientDescription: String? = nil) -> [String: String]? {
        let machineID = firstValue(in: raw, keys: "machineID", "X-Apple-I-MD-M", "X-Apple-MD-M")
        let otp = firstValue(in: raw, keys: "oneTimePassword", "X-Apple-I-MD", "X-Apple-MD")
        guard let machineID, let otp else { return nil }

        let localUserID = firstValue(in: raw, keys: "localUserID", "X-Apple-I-MD-LU")
            ?? persistentLocalUserID()
        let routingInfo = firstValue(in: raw, keys: "routingInfo", "X-Apple-I-MD-RINFO")
            ?? defaultRoutingInfo
        let deviceID = firstValue(in: raw, keys: "deviceUniqueIdentifier", "X-Mme-Device-Id", "X-Mme-Device-ID")
            ?? persistentDeviceIdentifier()
        let serial = firstValue(in: raw, keys: "deviceSerialNumber", "X-Apple-I-SRL-NO") ?? "0"
        let override = clientDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (override?.isEmpty == false ? override : nil)
            ?? firstValue(in: raw, keys: "deviceDescription", "X-MMe-Client-Info", "X-Mme-Client-Info")
            ?? compatibilityClientDescription
        let date = firstValue(in: raw, keys: "date", "X-Apple-I-Client-Time")
            ?? ISO8601DateFormatter().string(from: Date())
        let locale = firstValue(in: raw, keys: "locale", "X-Apple-Locale", "X-Apple-I-Locale")
            ?? Locale.current.identifier
        let timeZone = firstValue(in: raw, keys: "timeZone", "X-Apple-I-TimeZone")
            ?? TimeZone.current.abbreviation()
            ?? "UTC"

        return [
            "machineID": machineID,
            "oneTimePassword": otp,
            "localUserID": localUserID,
            "routingInfo": routingInfo,
            "deviceUniqueIdentifier": deviceID,
            "deviceSerialNumber": serial,
            "deviceDescription": description,
            "date": date,
            "locale": locale,
            "timeZone": timeZone
        ]
    }

    static func stringify(_ object: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else if let bool = value as? Bool {
                result[key] = bool ? "true" : "false"
            }
        }
        return result
    }

    private static func firstValue(in raw: [String: String], keys: String...) -> String? {
        for key in keys {
            if let value = raw[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
            if let match = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !match.isEmpty {
                return match
            }
        }
        return nil
    }

    private static func persistentLocalUserID() -> String {
        persistentHex("forgesign.anisette.localUserID")
    }

    private static func persistentDeviceIdentifier() -> String {
        let stored = UserDefaults.standard.string(forKey: "forgesign.anisette.deviceID")
        if let stored, !stored.isEmpty { return stored }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "forgesign.anisette.deviceID")
        return value
    }

    private static func persistentHex(_ key: String) -> String {
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

enum OnDeviceAnisette {
    static let isAvailable: Bool = {
        loadAuthKit()
        return NSClassFromString("AKAppleIDSession") != nil
            && NSClassFromString("AKDevice") != nil
    }()

    static func json() -> [String: String]? {
        loadAuthKit()
        guard let sessionClass = NSClassFromString("AKAppleIDSession"),
              let deviceClass = NSClassFromString("AKDevice") else { return nil }

        let allocated = (sessionClass as AnyObject)
            .perform(NSSelectorFromString("alloc"))?
            .takeRetainedValue()
        guard let allocated else { return nil }
        guard let session = allocated
            .perform(NSSelectorFromString("initWithIdentifier:"), with: "com.apple.gs.xcode.auth")?
            .takeUnretainedValue() as? NSObject else { return nil }

        let headerSelector = NSSelectorFromString("appleIDHeadersForRequest:")
        guard session.responds(to: headerSelector) else { return nil }
        guard let requestURL = URL(string: "https://developerservices2.apple.com/") else {
            return nil
        }
        let request = NSURLRequest(url: requestURL)
        guard let headers = session.perform(headerSelector, with: request)?
            .takeUnretainedValue() as? [AnyHashable: Any] else { return nil }

        let currentSelector = NSSelectorFromString("currentDevice")
        guard (deviceClass as AnyObject).responds(to: currentSelector),
              let device = (deviceClass as AnyObject).perform(currentSelector)?
                .takeUnretainedValue() as? NSObject else { return nil }

        // Do not use Dictionary(uniqueKeysWithValues:) here. AuthKit may
        // expose equivalent header keys with different casing/types; that
        // initializer traps on a collision and would terminate ForgeSign
        // while the AltServer flow is starting.
        var rawHeaders: [String: Any] = [:]
        for (key, value) in headers {
            guard let name = key as? String else { continue }
            rawHeaders[name] = value
        }
        var raw = AnisettePayload.stringify(rawHeaders)
        if let deviceID = string(from: device, selector: "uniqueDeviceIdentifier") {
            raw["deviceUniqueIdentifier"] = deviceID
        }
        if let serial = string(from: device, selector: "serialNumber") {
            raw["deviceSerialNumber"] = serial
        }
        if let description = string(from: device, selector: "serverFriendlyDescription") {
            raw["deviceDescription"] = description
        }
        return AnisettePayload.json(from: raw)
    }

    @discardableResult
    private static func loadAuthKit() -> Bool {
        #if canImport(Darwin)
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW) != nil
            || NSClassFromString("AKAppleIDSession") != nil
        #else
        NSClassFromString("AKAppleIDSession") != nil
        #endif
    }

    private static func string(from object: NSObject, selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel)?.takeUnretainedValue() as? String
    }
}

enum AnisetteHTTPClient {
    static func fetch(from url: URL, clientDescription: String? = nil) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AltServerClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AltServerClientError.httpStatus(http.statusCode)
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let json = AnisettePayload.json(
               from: AnisettePayload.stringify(object),
               clientDescription: clientDescription
           ) {
            return json
        }

        var raw: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let string = value as? String {
                raw[name] = string
            }
        }
        if let json = AnisettePayload.json(from: raw, clientDescription: clientDescription) {
            return json
        }

        throw AltServerClientError.invalidResponse
    }
}
