import SwiftUI

struct AutomaticProvisioningSection: View {
    @Binding var isEnabled: Bool
    @Binding var appleID: String
    @Binding var applePassword: String
    @Binding var deviceIdentifier: String
    @Binding var anisetteModeRaw: String
    @Binding var remoteServerAddress: String
    @Binding var customAnisetteURL: String

    @ObservedObject var altServer: AltServerClient
    @ObservedObject var provisioner: AltServerProvisioningService

    @Environment(\.forgeTheme) private var T
    @State private var isRefreshingServerList = false

    private var mode: AnisetteMode {
        AnisettePreference.resolvedMode(storedMode: anisetteModeRaw, legacyCustomURLText: customAnisetteURL)
    }

    private var plan: AnisettePreference.Plan {
        AnisettePreference.plan(mode: mode,
                                remoteServerAddress: remoteServerAddress.isEmpty ? nil : remoteServerAddress,
                                customURLText: customAnisetteURL)
    }

    var body: some View {
        GlassSection("Provisioning") {
            VStack(spacing: 0) {
                GlassToggleRow(label: "Use Apple Account provisioning", isOn: $isEnabled)
                if isEnabled {
                    GlassRowDivider()
                    anisetteRow
                    if mode == .customURL {
                        GlassRowDivider()
                        GlassInputRow(icon: "link",
                                      label: "Anisette URL",
                                      placeholder: "http://MAC-IP:6969",
                                      text: $customAnisetteURL)
                    }
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
                    statusRow
                    GlassRowDivider()
                    MonoText(text: anisetteHint, size: 9, color: T.ink4)
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
        .onDisappear {
            altServer.stopSearching()
        }
    }

    // MARK: - Anisette source

    private var anisetteRow: some View {
        GlassRow(label: "Anisette source") {
            HStack(spacing: 8) {
                Menu {
                    Button {
                        anisetteModeRaw = AnisetteMode.automatic.rawValue
                    } label: {
                        Label(AnisetteMode.automatic.displayName, systemImage: "wand.and.stars")
                    }

                    Menu {
                        ForEach(RemoteAnisetteCatalog.available()) { server in
                            Button(server.name) {
                                remoteServerAddress = server.address
                                anisetteModeRaw = AnisetteMode.remoteServer.rawValue
                            }
                        }
                        Divider()
                        Button {
                            refreshServerList()
                        } label: {
                            Label("Update server list", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Label(AnisetteMode.remoteServer.displayName, systemImage: "cloud")
                    }

                    Button {
                        anisetteModeRaw = AnisetteMode.customURL.rawValue
                    } label: {
                        Label(AnisetteMode.customURL.displayName, systemImage: "link")
                    }
                    Button {
                        anisetteModeRaw = AnisetteMode.thisDevice.rawValue
                    } label: {
                        Label(AnisetteMode.thisDevice.displayName, systemImage: "iphone")
                    }
                    Button {
                        anisetteModeRaw = AnisetteMode.altServerOnly.rawValue
                    } label: {
                        Label(AnisetteMode.altServerOnly.displayName, systemImage: "desktopcomputer")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(anisetteLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(T.sans(13, .medium))
                    .foregroundColor(T.accent2)
                }
                .accessibilityLabel("Anisette source")
                .accessibilityValue(anisetteLabel)

                if isRefreshingServerList {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { await altServer.checkAnisette(plan: plan) }
                } label: {
                    if altServer.isCheckingAnisette {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(T.accent2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(altServer.isCheckingAnisette)
                .accessibilityLabel("Test anisette source")
            }
        }
    }

    // MARK: - AltServer

    private var serverRow: some View {
        GlassRow(label: "AltServer") {
            HStack(spacing: 8) {
                if altServer.servers.isEmpty {
                    if altServer.isSearching {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                            .font(T.sans(13, .medium))
                            .foregroundColor(T.ink3)
                    } else if plan.useAltServer {
                        Text("Not found")
                            .font(T.sans(13, .medium))
                            .foregroundColor(plan.remoteServers.isEmpty && plan.customURL == nil ? T.bad : T.ink3)
                    } else {
                        Text("Off")
                            .font(T.sans(13, .medium))
                            .foregroundColor(T.ink3)
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

    // MARK: - Status

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: provisioner.phase == .idle ? "checkmark.circle" : "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(provisioner.phase == .idle ? T.ink3 : T.accent2)
                Text(statusLabel)
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let error = altServer.discoveryError {
                    Text(error)
                        .font(T.mono(9))
                        .foregroundColor(T.bad)
                        .lineLimit(1)
                }
            }
            if let result = altServer.anisetteCheckResult {
                Text(result)
                    .font(T.mono(9))
                    .foregroundColor(result.localizedCaseInsensitiveContains("received") ? T.good : T.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var anisetteLabel: String {
        switch mode {
        case .automatic:
            return plan.remoteServers.first.map { "Auto · \($0.name)" } ?? "Automatic"
        case .remoteServer:
            return remoteServerAddress.isEmpty
                ? AnisetteMode.remoteServer.displayName
                : (RemoteAnisetteCatalog.server(forAddress: remoteServerAddress)?.name ?? "Remote server")
        default:
            return mode.displayName
        }
    }

    private var anisetteHint: String {
        switch mode {
        case .automatic, .remoteServer, .customURL:
            return "Remote anisette servers only relay the Apple sign-in handshake — your Apple password goes to Apple, never to the server. Existing AltStore certificates are not revoked."
        case .thisDevice:
            return "Uses only this iPhone's Apple sign-in data. If Apple rejects it, switch to Automatic to use a remote anisette server."
        case .altServerOnly:
            return "Uses AltServer on your local network only. On macOS 27 AltServer can fail to read machineID; switch to Automatic or a remote server if that happens."
        }
    }

    private var statusLabel: String {
        guard provisioner.phase == .idle else { return provisioner.statusText }

        if appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter Apple Account email"
        }
        if applePassword.isEmpty {
            return "Enter Apple Account password"
        }
        if deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter device UDID"
        }
        if let source = altServer.lastSource {
            if let name = altServer.lastRemoteServerName, source == .remoteServer || source == .httpServer {
                return "Using \(name)"
            }
            return "Using \(source.rawValue)"
        }
        if !altServer.hasAnisetteSource(plan: plan) && !altServer.isSearching {
            return "Waiting for AltServer or anisette server"
        }
        return "Ready · \(plan.summary)"
    }

    private func refreshServerList() {
        guard !isRefreshingServerList else { return }
        isRefreshingServerList = true
        Task {
            defer { isRefreshingServerList = false }
            if let servers = await RemoteAnisetteCatalog.fetchPublished() {
                RemoteAnisetteCatalog.store(servers)
            }
        }
    }
}
