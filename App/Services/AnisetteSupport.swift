import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum AnisetteSource: String, Equatable, Sendable {
    case thisDevice = "This iPhone"
    case altServer = "AltServer"
    case altServerHost = "Anisette server on the AltServer Mac"
    case httpServer = "Anisette server"
}

enum AnisettePayload {
    static let defaultRoutingInfo = "17106176"

    static func json(from raw: [String: String]) -> [String: String]? {
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
        let description = firstValue(in: raw, keys: "deviceDescription", "X-MMe-Client-Info", "X-Mme-Client-Info")
            ?? defaultDeviceDescription
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

    private static let defaultDeviceDescription =
        "<MacBookPro18,3> <macOS;13.4.1;22F82> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"

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
    static var isAvailable: Bool {
        loadAuthKit()
        return NSClassFromString("AKAppleIDSession") != nil
            && NSClassFromString("AKDevice") != nil
    }

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
        let request = NSURLRequest(url: URL(string: "https://developerservices2.apple.com/")!)
        guard let headers = session.perform(headerSelector, with: request)?
            .takeUnretainedValue() as? [AnyHashable: Any] else { return nil }

        let currentSelector = NSSelectorFromString("currentDevice")
        guard (deviceClass as AnyObject).responds(to: currentSelector),
              let device = (deviceClass as AnyObject).perform(currentSelector)?
                .takeUnretainedValue() as? NSObject else { return nil }

        var raw = AnisettePayload.stringify(Dictionary(
            uniqueKeysWithValues: headers.compactMap { key, value in
                guard let name = key as? String else { return nil }
                return (name, value)
            }
        ))
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
    static func fetch(from url: URL) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let json = AnisettePayload.json(from: AnisettePayload.stringify(object)) {
            return json
        }

        if let http = response as? HTTPURLResponse {
            var raw: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let string = value as? String {
                    raw[name] = string
                }
            }
            if let json = AnisettePayload.json(from: raw) {
                return json
            }
        }

        throw AltServerClientError.invalidResponse
    }
}
