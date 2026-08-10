import SwiftUI

struct AppsView: View {
    @Environment(\.forgeTheme) private var T
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var certStore: CertificateStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installer: InstallController

    @State private var query = ""
    @State private var showAbout = false
    @State private var selected: FeedApp?
    @State private var selectedCategory: String? = nil

    @State private var pendingInstall: (app: FeedApp, version: FeedVersion)? = nil
    @State private var showCertSheet = false
    @State private var showProfileSheet = false
    @State private var showSourcesEditor = false
    @State private var showPasswordPrompt = false

    @State private var alertMessage: String?
    @State private var isShowingAlert = false

    var filtered: [FeedApp] {
        var arr = sources.apps
        if let cat = selectedCategory, cat != "All" {
            arr = arr.filter { ($0.tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(cat) }) }
        }
        if query.isEmpty { return arr }
        return arr.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query)
            || ($0.developer ?? "").localizedCaseInsensitiveContains(query)
            || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private var categories: [String] {
        let allTags = sources.apps.compactMap { $0.tags }.flatMap { $0 }
        let unique = Set(allTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter { !$0.isEmpty }
        var list = ["All"]
        list.append(contentsOf: unique.sorted())
        return list
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeBackdrop()
                ScrollView {
                    VStack(spacing: 12) {
                        featuredCarousel()
                        categoriesSection
                        GlassSection("All Apps") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                                ForEach(filtered, id: \.bundleIdentifier) { app in
                                    AppCardView(app: app) {
                                        selected = app
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .padding(.bottom, 40)
                    }
                    .padding(.top, 12)
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search apps or developer")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 10) {
                            Button { showAbout = true } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(GlassTactileButtonStyle())

                            Menu {
                                Button("Refresh sources") { Task { await sources.refreshAll() } }
                                Button("Manage sources") { showSourcesEditor = true }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(GlassTactileButtonStyle())
                        }
                    }
                }
                .sheet(isPresented: $showAbout) { AboutView() }
                .sheet(isPresented: Binding(
                    get: { selected != nil },
                    set: { if !$0 { selected = nil } }
                )) {
                    if let app = selected {
                        AppDetailSheet(app: app) { version in
                            Task { await startInstallFlow(app: app, version: version) }
                        }
                        .environmentObject(certStore)
                        .environmentObject(profileStore)
                    }
                }
                .sheet(isPresented: $showCertSheet) {
                    CertificatesSheet()
                }
                .sheet(isPresented: $showProfileSheet) {
                    ProfilesSheet()
                }
                .sheet(isPresented: $showSourcesEditor) {
                    SourcesSettingsView()
                        .environmentObject(sources)
                }
                .sheet(isPresented: $showPasswordPrompt) {
                    if let cert = certStore.selected {
                        PasswordPromptSheet(cert: cert) { pw, remember in
                            if remember {
                                PasswordVault.save(pw, for: cert.id)
                            }
                            Task {
                                if let pending = pendingInstall {
                                    pendingInstall = nil
                                    await downloadSignAndInstall(app: pending.app, version: pending.version, password: pw)
                                }
                            }
                        }
                    }
                }
                .onChange(of: certStore.selectedID) { _ in
                    attemptPendingInstallIfReady()
                }
                .onChange(of: profileStore.selectedID) { _ in
                    attemptPendingInstallIfReady()
                }
                .alert("Error", isPresented: $isShowingAlert, actions: {
                    Button("OK", role: .cancel) {}
                }, message: {
                    Text(alertMessage ?? "An error occurred.")
                })
            }
            .forgeTheme(T)
            .forgeScaledType()
        }
    }

    private func featuredCarousel() -> some View {
        let featured = Array(sources.apps.prefix(5))
        return TabView {
            ForEach(featured, id: \.bundleIdentifier) { app in
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: app.iconURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(height: 160)
                    .clipped()
                    .fGlass(cornerRadius: 14)
                    VStack(alignment: .leading) {
                        Text(app.title ?? app.bundleIdentifier).font(T.display(18)).foregroundColor(T.ink)
                        Text(app.developer ?? "").font(T.mono(12)).foregroundColor(T.ink2)
                    }
                    .padding(12)
                }
                .padding(.horizontal, 12)
                .onTapGesture {
                    selected = app
                }
            }
        }
        .frame(height: 170)
        .tabViewStyle(.page(indexDisplayMode: .always))
    }

    private var categoriesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    Button {
                        withAnimation { selectedCategory = (cat == "All") ? nil : cat }
                    } label: {
                        Text(cat)
                            .font(T.sans(13))
                            .foregroundColor(selectedCategory == nil && cat == "All" ? T.ink : (selectedCategory == cat ? .white : T.ink))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedCategory == cat ? T.accent : Color.clear)
                            .fGlass(cornerRadius: 12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.rule2, lineWidth: AppStroke.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 56)
    }

    private func startInstallFlow(app: FeedApp, version: FeedVersion) async {
        guard let cert = certStore.selected else {
            pendingInstall = (app, version)
            showCertSheet = true
            return
        }
        guard profileStore.selected != nil else {
            pendingInstall = (app, version)
            showProfileSheet = true
            return
        }
        if certStore.savedPassword(for: cert) == nil {
            pendingInstall = (app, version)
            showPasswordPrompt = true
            return
        }
        let pw = certStore.savedPassword(for: cert) ?? ""
        await downloadSignAndInstall(app: app, version: version, password: pw)
    }

    private func attemptPendingInstallIfReady() {
        guard let pending = pendingInstall else { return }
        if let cert = certStore.selected, profileStore.selected != nil,
           let pw = certStore.savedPassword(for: cert) {
            Task {
                pendingInstall = nil
                showCertSheet = false
                showProfileSheet = false
                await downloadSignAndInstall(app: pending.app, version: pending.version, password: pw)
            }
        }
    }

    private func downloadSignAndInstall(app: FeedApp, version: FeedVersion, password: String) async {
        let signer = SigningService()
        let tempName = "\(app.bundleIdentifier)-\(version.version).ipa"
        let downloadDest = signer.workDir.appendingPathComponent(tempName)
        do {
            try? FileManager.default.removeItem(at: downloadDest)
            let (tempURL, _) = try await URLSession.shared.download(from: version.downloadURL)
            try FileManager.default.moveItem(at: tempURL, to: downloadDest)
        } catch {
            alertMessage = "Download failed: \(error.localizedDescription)"
            isShowingAlert = true
            return
        }

        guard let cert = certStore.selected else {
            alertMessage = "Certificate was deselected."
            isShowingAlert = true
            return
        }
        guard let profile = profileStore.selected else {
            alertMessage = "Provisioning profile missing."
            isShowingAlert = true
            return
        }

        let p12 = certStore.fileURL(for: cert)
        let profileFile = profileStore.fileURL(for: profile)
        let outName = downloadDest.deletingPathExtension().lastPathComponent + "-signed.ipa"
        let output = history.signedDir.appendingPathComponent(outName)

        let result = await Task.detached(priority: .userInitiated) {
            SigningService.sign(
                ipa: downloadDest,
                p12: p12,
                password: password,
                profile: profileFile,
                bundleId: "",
                output: output,
                tempDir: signer.tempDir,
                removeExtensions: false,
                enableDocuments: false
            )
        }.value

        if result.ok {
            _ = history.append(inputName: downloadDest.lastPathComponent,
                                outputName: outName,
                                bundleId: result.signedBundleId,
                                version: result.signedVersion,
                                certificateCN: cert.commonName)
            installer.install(ipa: output, bundleId: result.signedBundleId, version: result.signedVersion)
        } else {
            alertMessage = "Signing failed: \(result.message)"
            isShowingAlert = true
        }
    }
}
