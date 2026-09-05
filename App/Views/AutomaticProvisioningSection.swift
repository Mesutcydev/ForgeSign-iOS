import SwiftUI

struct AutomaticProvisioningSection: View {
    @Binding var isEnabled: Bool
    @Binding var appleID: String
    @Binding var applePassword: String
    @Binding var deviceIdentifier: String
    @Binding var anisetteServerURL: String

    @ObservedObject var altServer: AltServerClient
    @ObservedObject var provisioner: AltServerProvisioningService

    @Environment(\.forgeTheme) private var T

    var body: some View {
        GlassSection("Provisioning") {
            VStack(spacing: 0) {
                GlassToggleRow(label: "Use Apple Account with AltServer", isOn: $isEnabled)
                if isEnabled {
                    GlassRowDivider()
                    serverRow
                    GlassRowDivider()
                    GlassInputRow(icon: "person.crop.circle",
                                  label: "Apple Account",
                                  placeholder: "name@example.com",
                                  text: $appleID)
                    GlassRowDivider()
                    GlassInputRow(icon: "lock.fill",
                                  label: "Password",
                                  placeholder: "Not saved",
                                  text: $applePassword,
                                  isSecure: true)
                    GlassRowDivider()
                    GlassInputRow(icon: "iphone",
                                  label: "Device UDID",
                                  placeholder: "Injected when installed by AltStore",
                                  text: $deviceIdentifier)
                    GlassRowDivider()
                    GlassInputRow(icon: "link",
                                  label: "Anisette URL",
                                  placeholder: "Optional http://MAC-IP:6969",
                                  text: $anisetteServerURL)
                    GlassRowDivider()
                    statusRow
                    GlassRowDivider()
                    MonoText(
                        text: "On iOS/macOS 27 AltServer often cannot read machineID. ForgeSign tries this iPhone first, then AltServer, then an anisette server on port 6969. Your password is sent only to Apple. Existing AltStore certificates are not revoked.",
                        size: 9,
                        color: T.ink4
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }
        }
        .onAppear {
            guard isEnabled else { return }
            altServer.startSearching()
        }
        .onChange(of: isEnabled) { enabled in
            if enabled {
                altServer.startSearching()
            } else {
                altServer.stopSearching()
            }
        }
    }

    private var serverRow: some View {
        GlassRow(label: "AltServer") {
            HStack(spacing: 8) {
                if altServer.servers.isEmpty {
                    if altServer.isSearching {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                            .font(T.sans(13, .medium))
                            .foregroundColor(T.ink3)
                    } else if OnDeviceAnisette.isAvailable || !anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Optional")
                            .font(T.sans(13, .medium))
                            .foregroundColor(T.ink3)
                    } else {
                        Text("Not found")
                            .font(T.sans(13, .medium))
                            .foregroundColor(T.bad)
                    }
                } else {
                    Menu {
                        ForEach(altServer.servers) { server in
                            Button(server.name) { altServer.selectedServerID = server.id }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(altServer.selectedServer?.name ?? "Choose")
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(T.sans(13, .medium))
                        .foregroundColor(T.accent2)
                    }
                }
                Button {
                    altServer.stopSearching()
                    altServer.startSearching()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(T.accent2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search for AltServer again")
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: provisioner.phase == .idle ? "checkmark.circle" : "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(provisioner.phase == .idle ? T.ink3 : T.accent2)
            Text(statusLabel)
                .font(T.mono(10))
                .foregroundColor(T.ink3)
            Spacer()
            if let error = altServer.discoveryError {
                Text(error)
                    .font(T.mono(9))
                    .foregroundColor(T.bad)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusLabel: String {
        if let source = altServer.lastSource {
            return "Using \(source.rawValue)"
        }
        if OnDeviceAnisette.isAvailable {
            return "Ready on this iPhone"
        }
        return provisioner.statusText
    }
}
