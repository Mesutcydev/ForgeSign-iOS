import SwiftUI
import UIKit

/// Device Installation: pairing records, the tunnel, and an honest health check.
/// Nothing here pretends the direct transport exists — unavailable services say
/// so instead of showing a green tick.
struct DeviceInstallationSection: View {
    @ObservedObject var model: DeviceInstallationModel
    let availableMethods: [InstallationMethod]
    let expectedUDID: String?
    let anisetteSource: String
    /// Message surfaced when a pairing file arrived via Open-In / share sheet.
    var importMessage: String?
    var onImportMessageShown: (() -> Void)? = nil

    @Environment(\.forgeTheme) private var T
    @State private var showImporter = false
    @State private var didCopy = false

    var body: some View {
        GlassSection("Device Installation") {
            VStack(spacing: 0) {
                pairingRow
                GlassRowDivider()
                tunnelRow
                if let health = model.health {
                    GlassRowDivider()
                    healthRows(health)
                }
                GlassRowDivider()
                actions
                GlassRowDivider()
                detailText
            }
        }
        .fullScreenCover(isPresented: $showImporter) {
            ForgeDocumentPicker { url in
                Task { @MainActor in showImporter = false }
                guard ["mobiledevicepairing", "plist"].contains(url.pathExtension.lowercased()) else {
                    model.note("Choose a .mobiledevicepairing or .plist pairing record.")
                    return
                }
                model.importPairing(from: url)
                model.refresh(availableMethods: availableMethods, expectedUDID: expectedUDID)
            }
        }
        .task {
            model.refresh(availableMethods: availableMethods, expectedUDID: expectedUDID)
        }
    }

    // MARK: - Rows

    private var pairingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassRow(label: "Pairing") {
                HStack(spacing: 8) {
                    GlassStatusPill(text: pairingPillText, color: pairingPillColor)
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import Pairing File…", systemImage: "square.and.arrow.down")
                        }
                        if model.hasRecord {
                            Button(role: .destructive) {
                                model.removeAll()
                                model.refresh(availableMethods: availableMethods, expectedUDID: expectedUDID)
                            } label: {
                                Label("Remove Pairing Record", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(T.accent2)
                    }
                    .accessibilityLabel("Pairing options")
                }
            }
            Text(model.hasRecord
                 ? "\(model.pairing.summary) · \(model.records.count) record\(model.records.count == 1 ? "" : "s")"
                 : "Import a pairing record exported by AltStore, SideStore or idevice_pair.")
                .font(T.mono(9))
                .foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var tunnelRow: some View {
        GlassRow(label: "Local tunnel") {
            HStack(spacing: 8) {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
                GlassStatusPill(text: tunnelPillText, color: tunnelPillColor)
                Button {
                    Task { await model.runFullCheck(availableMethods: availableMethods,
                                                    expectedUDID: expectedUDID,
                                                    customHost: nil) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(T.accent2)
                }
                .buttonStyle(.plain)
                .disabled(model.isChecking)
                .accessibilityLabel("Check the local tunnel")
            }
        }
    }

    private func healthRows(_ health: DeviceInstallHealth) -> some View {
        VStack(spacing: 0) {
            ForEach(health.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.status.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color(for: row.status))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(T.sans(13, .semibold))
                            .foregroundColor(T.ink)
                        Text(row.detail)
                            .font(T.mono(9))
                            .foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if row.id != health.rows.last?.id {
                    GlassRowDivider()
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: T.gap) {
            GlassSecondaryButton(label: model.isChecking ? "Running Checks…" : "Run Full Check",
                                 systemImage: "stethoscope") {
                Task { await model.runFullCheck(availableMethods: availableMethods,
                                                expectedUDID: expectedUDID,
                                                customHost: nil) }
            }
            GlassSecondaryButton(label: didCopy ? "Copied" : "Copy Diagnostics",
                                 systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = model.diagnosticsReport(availableMethods: availableMethods,
                                                                      expectedUDID: expectedUDID,
                                                                      anisetteSource: anisetteSource)
                didCopy = true
            }
        }
        .padding(16)
    }

    private var detailText: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.message {
                Text(message)
                    .font(T.mono(9))
                    .foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let importMessage {
                Text(importMessage)
                    .font(T.mono(9))
                    .foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .task { onImportMessageShown?() }
            }
            Text("Pairing records are stored in this device's Keychain only (no iCloud, no backups) and are never included in diagnostics. Pairing files (`.mobiledevicepairing` / `.plist`) sent from Files or other apps land here automatically.")
                .font(T.mono(9))
                .foregroundColor(T.ink4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Presentation helpers

    private var pairingPillText: String {
        if !model.hasRecord { return "not set" }
        return model.pairing.isUsable ? "paired" : "check"
    }

    private var pairingPillColor: Color {
        if !model.hasRecord { return T.ink3 }
        return model.pairing.isUsable ? T.good : T.warn
    }

    private var tunnelPillText: String {
        if model.isChecking { return "checking" }
        guard let tunnel = model.tunnel else { return "unknown" }
        return "\(tunnel.source.rawValue) · ok"
    }

    private var tunnelPillColor: Color {
        if model.isChecking { return T.accent2 }
        return model.tunnel == nil ? T.ink3 : T.good
    }

    private func color(for status: DeviceInstallHealthRow.Status) -> Color {
        switch status {
        case .ok: return T.good
        case .warning: return T.warn
        case .failed: return T.bad
        case .unknown, .unavailable: return T.ink3
        }
    }
}