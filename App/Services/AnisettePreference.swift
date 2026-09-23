import Foundation

/// Where ForgeSign is allowed to obtain anisette data (the Apple sign-in
/// material AltSign needs). The order is always most-specific first, and every
/// mode keeps a working fallback so sign-in never dead-ends.
enum AnisetteMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case remoteServer
    case customURL
    case thisDevice
    case altServerOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .remoteServer: return "Remote server"
        case .customURL: return "Custom URL"
        case .thisDevice: return "This iPhone"
        case .altServerOnly: return "AltServer"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Tries a remote anisette server, then AltServer on your network, then this iPhone."
        case .remoteServer:
            return "Uses one remote anisette server, then falls back to AltServer and this iPhone."
        case .customURL:
            return "Uses an anisette server you run yourself."
        case .thisDevice:
            return "Uses this iPhone's own Apple sign-in data. Nothing leaves the device."
        case .altServerOnly:
            return "Uses AltServer on your local network only."
        }
    }
}

enum AnisettePreference {
    static let defaultMode: AnisetteMode = .automatic

    /// Remote server attempts are capped so a bad list cannot stall sign-in.
    static let maximumRemoteAttempts = 3

    struct Plan: Equatable, Sendable {
        var remoteServers: [RemoteAnisetteServer] = []
        var customURL: URL?
        var useAltServer: Bool = true
        var useThisDevice: Bool = true

        var summary: String {
            var parts: [String] = []
            if let customURL { parts.append(customURL.host ?? customURL.absoluteString) }
            parts.append(contentsOf: remoteServers.map(\.name))
            if useAltServer { parts.append("AltServer") }
            if useThisDevice { parts.append("this iPhone") }
            return parts.joined(separator: " → ")
        }
    }

    static func mode(fromStored raw: String) -> AnisetteMode {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "device", "thisdevice", "this_iphone", "ondevice": return .thisDevice
        case "altserver", "altserveronly": return .altServerOnly
        case "remote", "remoteserver": return .remoteServer
        case "custom", "customurl": return .customURL
        default: return AnisetteMode(rawValue: value) ?? defaultMode
        }
    }

    static func parseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Resolves the stored preference into the ordered source list a fetch uses.
    static func plan(mode: AnisetteMode,
                     remoteServerAddress: String?,
                     customURLText: String) -> Plan {
        let customURL = parseURL(customURLText)

        switch mode {
        case .automatic:
            return Plan(remoteServers: Array(RemoteAnisetteCatalog.available().prefix(maximumRemoteAttempts)),
                        customURL: customURL,
                        useAltServer: true,
                        useThisDevice: true)

        case .remoteServer:
            let selected = remoteServerAddress
                .flatMap { RemoteAnisetteCatalog.server(forAddress: $0) }
                ?? RemoteAnisetteCatalog.available().first
            return Plan(remoteServers: selected.map { [$0] } ?? [],
                        customURL: nil,
                        useAltServer: true,
                        useThisDevice: true)

        case .customURL:
            return Plan(remoteServers: [],
                        customURL: customURL,
                        useAltServer: true,
                        useThisDevice: true)

        case .thisDevice:
            return Plan(remoteServers: [],
                        customURL: nil,
                        useAltServer: false,
                        useThisDevice: true)

        case .altServerOnly:
            return Plan(remoteServers: [],
                        customURL: nil,
                        useAltServer: true,
                        useThisDevice: false)
        }
    }

    /// Stored mode plus the legacy free-text URL field, for pre-existing installs.
    static func resolvedMode(storedMode raw: String, legacyCustomURLText: String) -> AnisetteMode {
        let stored = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored.isEmpty else { return mode(fromStored: stored) }
        return parseURL(legacyCustomURLText) == nil ? defaultMode : .customURL
    }
}
