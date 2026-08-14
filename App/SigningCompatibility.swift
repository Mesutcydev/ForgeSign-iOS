import Foundation

struct SigningCompatibility {
    static func issues(inspection: IPAPreflight?, certificate: CertificateRecord?, profile: ProfileRecord?, bundleID: String, now: Date = .now) -> [String] {
        var issues: [String] = []

        guard let inspection else {
            issues.append("IPA inspection must finish before signing.")
            return issues
        }
        if inspection.encryptedExecutableCount > 0 {
            issues.append("The IPA contains encrypted executable files and cannot be signed.")
        }
        if inspection.extensionCount > 0 || inspection.watchAppCount > 0 {
            issues.append("Apps with extensions or Watch targets require a matching profile for each target.")
        }
        guard let certificate else {
            issues.append("Choose a signing certificate.")
            return issues
        }
        guard let profile else {
            issues.append("Choose a provisioning profile.")
            return issues
        }

        if let expiry = certificate.notAfter, expiry <= now {
            issues.append("The selected certificate has expired.")
        }
        if !profile.profileIsAuthentic {
            issues.append("Reimport the provisioning profile so its CMS signature can be verified.")
        }
        if let expiry = profile.notAfter, expiry <= now {
            issues.append("The selected provisioning profile has expired.")
        }
        if let certificateTeam = certificate.teamID,
           let profileTeam = profile.teamID,
           !certificateTeam.isEmpty,
           !profileTeam.isEmpty,
           certificateTeam.caseInsensitiveCompare(profileTeam) != .orderedSame {
            issues.append("The certificate and provisioning profile belong to different teams.")
        }

        let targetBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? inspection.bundleIdentifier
            : bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isValidBundleIdentifier(targetBundleID) {
            issues.append("The bundle ID is invalid.")
        } else if !profileCovers(profile.applicationIdentifier, bundleID: targetBundleID) {
            issues.append("The provisioning profile does not cover bundle ID \(targetBundleID).")
        }

        return issues
    }

    private static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 155,
              !identifier.hasPrefix("."), !identifier.hasSuffix("."),
              !identifier.contains("..") else { return false }
        return identifier.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar)
        }
    }

    private static func profileCovers(_ applicationIdentifier: String?, bundleID: String) -> Bool {
        guard let applicationIdentifier, let dot = applicationIdentifier.firstIndex(of: ".") else {
            return false
        }
        let pattern = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        if pattern == "*" || pattern == bundleID { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }
        let bundleParts = bundleID.split(separator: ".")
        let patternParts = pattern.split(separator: ".")
        guard bundleParts.count == patternParts.count else { return false }
        return zip(bundleParts, patternParts).allSatisfy { bundlePart, patternPart in
            patternPart == "*" || bundlePart == patternPart
        }
    }
}
