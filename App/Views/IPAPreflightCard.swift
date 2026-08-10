import SwiftUI

/// Read-only IPA diagnostics. This card intentionally reports findings without
/// disabling or changing the existing Sign button.
struct IPAPreflightCard: View {
    let state: IPAPreflightState
    let certificate: CertificateRecord?
    let profile: ProfileRecord?

    @Environment(\.forgeTheme) private var T

    @ViewBuilder
    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .inspecting:
            GlassSection("Preflight") {
                HStack(spacing: 10) {
                    ProgressView().tint(T.accent)
                    MonoText(text: "Inspecting IPA metadata…", size: 10, color: T.ink3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
        case .ready(let inspection):
            readyCard(inspection)
        case .failed(let message):
            GlassSection("Preflight") {
                diagnosticRow(icon: "exclamationmark.triangle.fill", color: T.warn,
                              title: "Inspection unavailable", detail: message)
            }
        }
    }

    private func readyCard(_ inspection: IPAPreflight) -> some View {
        GlassSection("Preflight") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(T.accent2)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(inspection.appName)
                            .font(T.sans(15, .medium))
                            .foregroundColor(T.ink)
                            .lineLimit(1)
                        Text(inspection.archiveSizeText)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                    }
                    Spacer(minLength: 8)
                    GlassStatusPill(text: "ready", color: T.good)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                GlassRowDivider()
                valueRow("Bundle ID", inspection.bundleIdentifier.isEmpty ? "unknown" : inspection.bundleIdentifier)
                GlassRowDivider()
                valueRow("Version", inspection.versionText)

                if let certificate {
                    GlassRowDivider()
                    valueRow("Certificate", certificate.organization ?? certificate.displayName)
                }

                if let profile {
                    GlassRowDivider()
                    valueRow("Profile", profile.displayName)
                    if let applicationIdentifier = profile.applicationIdentifier {
                        GlassRowDivider()
                        valueRow("Profile app ID", applicationIdentifier)
                    }
                }

                if let minimumOSVersion = inspection.minimumOSVersion {
                    GlassRowDivider()
                    valueRow("Minimum iOS", minimumOSVersion)
                }

                GlassRowDivider()
                valueRow("Bundle contents", contentsText(for: inspection))
                GlassRowDivider()
                valueRow("Executables", inspection.signatureText)

                if let mismatch = teamMismatch {
                    GlassRowDivider()
                    diagnosticRow(icon: "exclamationmark.triangle.fill", color: T.warn,
                                  title: "Team IDs differ", detail: mismatch)
                }

                if inspection.encryptedExecutableCount > 0 {
                    GlassRowDivider()
                    diagnosticRow(icon: "lock.trianglebadge.exclamationmark.fill", color: T.warn,
                                  title: "Encrypted executable detected",
                                  detail: encryptedDetail(for: inspection))
                }

                MonoText(text: "Informational only — signing behavior is unchanged.",
                         size: 9, color: T.ink4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        GlassRow(label: label) {
            Text(value)
                .font(T.mono(10))
                .foregroundColor(T.ink2)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .trailing)
        }
    }

    private func diagnosticRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(T.sans(13, .semibold))
                    .foregroundColor(T.ink)
                Text(detail)
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func contentsText(for inspection: IPAPreflight) -> String {
        var parts = ["\(inspection.nestedBundleCount) nested bundles"]
        if inspection.extensionCount > 0 { parts.append("\(inspection.extensionCount) extensions") }
        if inspection.frameworkCount > 0 { parts.append("\(inspection.frameworkCount) frameworks") }
        if inspection.watchAppCount > 0 { parts.append("\(inspection.watchAppCount) watch apps") }
        return parts.joined(separator: " · ")
    }

    private var teamMismatch: String? {
        guard let certificateTeam = certificate?.teamID,
              let profileTeam = profile?.teamID,
              !certificateTeam.isEmpty,
              !profileTeam.isEmpty,
              certificateTeam.caseInsensitiveCompare(profileTeam) != .orderedSame
        else { return nil }
        return "Certificate \(certificateTeam) · profile \(profileTeam). The current signing flow is unchanged."
    }

    private func encryptedDetail(for inspection: IPAPreflight) -> String {
        let count = inspection.encryptedExecutableCount
        if let first = inspection.encryptedPaths.first {
            return "\(count) Mach-O \(count == 1 ? "file is" : "files are") encrypted (for example, \(first))."
        }
        return "\(count) Mach-O \(count == 1 ? "file is" : "files are") encrypted."
    }
}
