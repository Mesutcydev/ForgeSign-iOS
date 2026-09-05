import SwiftUI

/// Read-only IPA diagnostics. This card intentionally reports findings without
/// disabling or changing the existing Sign button.
struct IPAPreflightCard: View {
    let state: IPAPreflightState
    let certificate: CertificateRecord?
    let profile: ProfileRecord?
    let audit: ProvisioningAudit?

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
                    GlassStatusPill(text: audit?.isReady == false ? "action needed" : "ready",
                                    color: audit?.isReady == false ? T.warn : T.good)
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

                if let audit {
                    GlassRowDivider()
                    ProvisioningAuditRows(rows: audit.rows)
                }

                MonoText(text: audit == nil
                         ? "Checking imported profiles…"
                         : "Matching profiles are used when available. Bundles without a dedicated profile use the app profile.",
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

private struct ProvisioningAuditRows: View {
    let rows: [ProvisioningAuditRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                ProvisioningAuditRowView(row: row)
                if row.id != rows.last?.id {
                    GlassRowDivider()
                }
            }
        }
    }
}

private struct ProvisioningAuditRowView: View {
    let row: ProvisioningAuditRow

    @Environment(\.forgeTheme) private var T

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.kind.displayName)
                        .font(T.sans(13, .semibold))
                        .foregroundColor(T.ink)
                    Spacer(minLength: 4)
                    GlassStatusPill(text: statusText, color: color)
                }
                Text(row.resolvedBundleID)
                    .font(T.mono(9))
                    .foregroundColor(T.ink2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(row.detail)
                    .font(T.mono(9))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.resolvedAppGroups.isEmpty {
                    Text("Groups: \(row.resolvedAppGroups.formatted())")
                        .font(T.mono(9))
                        .foregroundColor(T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var icon: String {
        switch row.state {
        case .ready: return "checkmark.seal.fill"
        case .warning: return "questionmark.diamond.fill"
        case .removed: return "minus.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch row.state {
        case .ready: return T.good
        case .warning, .removed: return T.warn
        default: return T.bad
        }
    }

    private var statusText: String {
        switch row.state {
        case .ready: return "ready"
        case .warning: return "check device"
        case .removed: return "removed"
        case .missingProfile: return "missing profile"
        case .wrongTeam: return "wrong team"
        case .wrongCertificate: return "wrong certificate"
        case .expired: return "expired"
        case .deviceMismatch: return "wrong device"
        case .missingAppGroups: return "missing groups"
        }
    }
}
