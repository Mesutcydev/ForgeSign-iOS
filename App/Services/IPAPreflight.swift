import Foundation

/// Read-only facts collected from an IPA before the existing signing flow is
/// invoked. The inspection does not validate or modify signing inputs.
struct IPAPreflight: Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String
    let shortVersion: String
    let buildVersion: String
    let minimumOSVersion: String?
    let nestedBundleCount: Int
    let extensionCount: Int
    let frameworkCount: Int
    let watchAppCount: Int
    let totalMachOCount: Int
    let signedMachOCount: Int
    let encryptedExecutableCount: Int
    let encryptedPaths: [String]
    let bundles: [SignableBundleInspection]
    let archiveBytes: Int64

    var versionText: String {
        switch (shortVersion.isEmpty, buildVersion.isEmpty) {
        case (false, false): return "\(shortVersion) (\(buildVersion))"
        case (false, true): return shortVersion
        case (true, false): return buildVersion
        case (true, true): return "unknown"
        }
    }

    var signatureText: String {
        guard totalMachOCount > 0 else { return "no Mach-O files" }
        return "\(signedMachOCount)/\(totalMachOCount) Mach-O files signed"
    }

    var archiveSizeText: String {
        ByteCountFormatter.string(fromByteCount: archiveBytes, countStyle: .file)
    }
}

struct SignableBundleInspection: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case app
        case `extension`
        case watchApp
        case appClip
        case nestedApp

        var displayName: String {
            switch self {
            case .app: return "App"
            case .extension: return "Extension"
            case .watchApp: return "Watch app"
            case .appClip: return "App Clip"
            case .nestedApp: return "Nested app"
            }
        }
    }

    var id: String { path }
    let path: String
    let kind: Kind
    let bundleIdentifier: String
    let entitlementsAvailable: Bool
    let requiredAppGroups: [String]
    let requiredKeychainAccessGroups: [String]
}

enum IPAPreflightState: Equatable, Sendable {
    case idle
    case inspecting
    case ready(IPAPreflight)
    case failed(String)
}

enum IPAPreflightError: LocalizedError, Sendable {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "IPA inspection is available in the on-device build."
        case .failed(let message):
            return message
        }
    }
}

enum IPAPreflightService {
    static func inspect(ipa: URL, temporaryDirectory: URL) -> Result<IPAPreflight, IPAPreflightError> {
        guard FileManager.default.fileExists(atPath: ipa.path),
              FileManager.default.isReadableFile(atPath: ipa.path) else {
            return .failure(.failed("The IPA is no longer available. Please choose it again."))
        }
        #if !FORGE_BRIDGE
        return .failure(.unavailable)
        #else
        var jsonBuffer = [CChar](repeating: 0, count: 32_768)
        var messageBuffer = [CChar](repeating: 0, count: 512)
        let status = forgesign_inspect_ipa(
            ipa.path,
            temporaryDirectory.path,
            &jsonBuffer,
            Int32(jsonBuffer.count),
            &messageBuffer,
            Int32(messageBuffer.count)
        )

        guard status == 0 else {
            let message = String(decoding: messageBuffer.prefix(while: { $0 != 0 })
                .map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return .failure(.failed(message.isEmpty ? "Could not inspect the IPA." : message))
        }

        let data = Data(jsonBuffer.prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) })
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let bytes = (try? ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            return .success(IPAPreflight(
                appName: payload.appName,
                bundleIdentifier: payload.bundleIdentifier,
                shortVersion: payload.shortVersion,
                buildVersion: payload.buildVersion,
                minimumOSVersion: payload.minimumOSVersion?.isEmpty == true ? nil : payload.minimumOSVersion,
                nestedBundleCount: payload.nestedBundleCount,
                extensionCount: payload.extensionCount,
                frameworkCount: payload.frameworkCount,
                watchAppCount: payload.watchAppCount,
                totalMachOCount: payload.totalMachOCount,
                signedMachOCount: payload.signedMachOCount,
                encryptedExecutableCount: payload.encryptedExecutableCount,
                encryptedPaths: payload.encryptedPaths,
                bundles: payload.bundles,
                archiveBytes: bytes
            ))
        } catch {
            return .failure(.failed("Inspection returned invalid metadata."))
        }
        #endif
    }

    #if FORGE_BRIDGE
    private struct Payload: Decodable, Sendable {
        let appName: String
        let bundleIdentifier: String
        let shortVersion: String
        let buildVersion: String
        let minimumOSVersion: String?
        let nestedBundleCount: Int
        let extensionCount: Int
        let frameworkCount: Int
        let watchAppCount: Int
        let totalMachOCount: Int
        let signedMachOCount: Int
        let encryptedExecutableCount: Int
        let encryptedPaths: [String]
        let bundles: [SignableBundleInspection]
    }
    #endif
}
