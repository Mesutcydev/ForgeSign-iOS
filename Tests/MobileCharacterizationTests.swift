import Foundation
import Testing
@testable import ForgeSignUISim

@Suite("Mobile characterization")
struct MobileCharacterizationTests {
    @Test("SwiftUI declares its scene lifecycle for clean launches")
    func sceneLifecycleRegistration() throws {
        let manifest = try #require(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        // The signing workspace and installer have one owner per process.
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == false)
    }

    @Test("IPA files expose ForgeSign from the Files preview")
    func ipaFilesQuickActionRegistration() throws {
        let documentTypes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]]
        )
        let ipaDocumentType = try #require(documentTypes.first { documentType in
            let contentTypes = documentType["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("com.apple.itunes.ipa") == true
        })

        #expect(ipaDocumentType["CFBundleTypeRole"] as? String == "Viewer")
        #expect(ipaDocumentType["LSHandlerRank"] as? String == "Alternate")

        let importedTypes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]]
        )
        let importedIPAType = try #require(importedTypes.first { importedType in
            importedType["UTTypeIdentifier"] as? String == "com.apple.itunes.ipa"
        })
        let tags = try #require(importedIPAType["UTTypeTagSpecification"] as? [String: Any])

        #expect(tags["public.filename-extension"] as? String == "ipa")
        #expect(tags["public.mime-type"] as? String == "application/x-ios-app")
    }

    @Test("Flat repository entries preserve the first download")
    func flatRepositoryEntry() throws {
        let data = Data(#"{"name":"Test","apps":[{"name":"Example","bundleIdentifier":"com.example.app","version":"1.0","downloadURL":"https://example.com/app.ipa","size":1234}]}"#.utf8)
        let source = try JSONDecoder().decode(RepoSource.self, from: data)
        let app = try #require(source.apps.first)

        #expect(app.version == "1.0")
        #expect(app.downloadURL?.absoluteString == "https://example.com/app.ipa")
        #expect(app.size == 1234)
        #expect(app.versions.count == 1)
    }

    @Test("Versioned repository entries preserve version metadata")
    func versionedRepositoryEntry() throws {
        let data = Data(#"{"name":"Test","apps":[{"name":"Example","bundleIdentifier":"com.example.app","versions":[{"version":"2.0","downloadURL":"https://example.com/app-2.ipa","size":"5678"}]}]}"#.utf8)
        let source = try JSONDecoder().decode(RepoSource.self, from: data)
        let app = try #require(source.apps.first)

        #expect(app.version == "2.0")
        #expect(app.downloadURL?.absoluteString == "https://example.com/app-2.ipa")
        #expect(app.size == 5678)
        #expect(app.versions.count == 1)
    }

    @Test("Missing IPA inspection returns a recovery message")
    func missingIPAInspection() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-file.ipa")
        let result = IPAPreflightService.inspect(
            ipa: missing,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )

        guard case .failure(.failed(let message)) = result else {
            Issue.record("Expected a missing-file inspection failure")
            return
        }
        #expect(message.contains("choose it again"))
    }

    @Test("Provisioning audit selects only the profiles needed by app and extension")
    func provisioningAuditSelectsMatchingProfiles() {
        let rootProfile = profile(name: "Root", appID: "TEAM.com.resigned.*",
                                  groups: ["group.resolved.shared"])
        let extensionProfile = profile(name: "Extension", appID: "TEAM.com.resigned.demo.shield",
                                       groups: ["group.resolved.shared"])
        let unrelated = profile(name: "Other", appID: "TEAM.com.unrelated.app")
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [rootProfile, extensionProfile, unrelated],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: false,
            deviceIdentifier: "DEVICE"
        )

        #expect(audit.isReady)
        #expect(audit.selectedProfileIDs == [rootProfile.id, extensionProfile.id])
        #expect(!audit.selectedProfileIDs.contains(unrelated.id))
        #expect(audit.rows.map(\.resolvedBundleID) == [
            "com.resigned.demo", "com.resigned.demo.shield"
        ])
    }

    @Test("Provisioning audit explains a missing extension profile")
    func provisioningAuditExplainsMissingExtension() {
        let rootProfile = profile(name: "Root", appID: "TEAM.com.resigned.demo",
                                  groups: ["group.resolved.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [rootProfile],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: false,
            deviceIdentifier: "DEVICE"
        )

        #expect(!audit.isReady)
        #expect(audit.rows.last?.state == .missingProfile)
        #expect(audit.firstBlockingMessage?.contains("com.resigned.demo.shield") == true)
    }

    @Test("Removing extensions keeps the established single-profile fallback")
    func provisioningAuditAllowsRemovedExtensions() {
        let rootProfile = profile(name: "Root", appID: "TEAM.com.resigned.demo",
                                  groups: ["group.resolved.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [rootProfile],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: true,
            deviceIdentifier: "DEVICE"
        )

        #expect(audit.isReady)
        #expect(audit.rows.last?.state == .removed)
        #expect(audit.selectedProfileIDs == [rootProfile.id])
    }

    @Test("Removing extensions does not hide a Watch app profile requirement")
    func provisioningAuditKeepsWatchAppRequirement() {
        let rootProfile = profile(name: "Root", appID: "TEAM.com.resigned.demo")
        let inspection = IPAPreflight(
            appName: "Demo", bundleIdentifier: "com.original.demo",
            shortVersion: "1.0", buildVersion: "1", minimumOSVersion: "16.0",
            nestedBundleCount: 1, extensionCount: 0, frameworkCount: 0,
            watchAppCount: 1, totalMachOCount: 2, signedMachOCount: 2,
            encryptedExecutableCount: 0, encryptedPaths: [],
            bundles: [
                SignableBundleInspection(path: "/", kind: .app,
                                         bundleIdentifier: "com.original.demo",
                                         entitlementsAvailable: true,
                                         requiredAppGroups: [],
                                         requiredKeychainAccessGroups: []),
                SignableBundleInspection(path: "Watch/Demo Watch.app", kind: .watchApp,
                                         bundleIdentifier: "com.original.demo.watchkitapp",
                                         entitlementsAvailable: true,
                                         requiredAppGroups: [],
                                         requiredKeychainAccessGroups: [])
            ],
            archiveBytes: 1_024
        )
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspection,
            profiles: [rootProfile],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: true,
            deviceIdentifier: "DEVICE"
        )

        #expect(!audit.isReady)
        #expect(audit.rows.last?.state == .missingProfile)
        #expect(audit.firstBlockingMessage?.contains("watchkitapp") == true)
    }

    @Test("Staged URL comparisons use normalized paths")
    func stagedURLComparison() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-sign-test")
        let normalized = base.appendingPathComponent("input.ipa")
        let equivalent = base
            .appendingPathComponent("subdir")
            .appendingPathComponent("..")
            .appendingPathComponent("input.ipa")

        #expect(normalized.standardizedFileURL.path == equivalent.standardizedFileURL.path)
    }

    @Test("HTTP routes are exact and query-safe")
    func httpRoutes() {
        #expect(LocalHTTPRoute.request("GET /app.ipa HTTP/1.1")?.path == "/app.ipa")
        #expect(LocalHTTPRoute.request("GET /app.ipa?retry=1 HTTP/1.1")?.path == "/app.ipa")
        #expect(LocalHTTPRoute.request("GET /app.ipax HTTP/1.1")?.path == "/app.ipax")
        #expect(LocalHTTPRoute.request("BROKEN") == nil)
    }

    @Test("HTTP ranges distinguish valid and invalid requests")
    func httpRanges() {
        #expect(LocalHTTPRange.parse(nil) == .absent)
        #expect(LocalHTTPRange.parse("bytes=0-99") == .bounded(start: 0, end: 99))
        #expect(LocalHTTPRange.parse("bytes=500-") == .openEnded(start: 500))
        #expect(LocalHTTPRange.parse("bytes=-100") == .suffix(100))
        #expect(LocalHTTPRange.parse("bytes=10-20,30-40") == .invalid)
        #expect(LocalHTTPRange.parse("items=0-1") == .invalid)
    }

    @Test("IPA transfer progress combines Range requests without counting retries twice")
    func ipaRangeProgress() {
        var progress = LocalIPAProgress()
        #expect(progress.record(offset: 0, length: 300, total: 1_000) == 0.3)
        #expect(progress.record(offset: 0, length: 300, total: 1_000) == 0.3)
        #expect(progress.record(offset: 600, length: 400, total: 1_000) == 0.7)
        #expect(!progress.isComplete(total: 1_000))
        #expect(progress.record(offset: 300, length: 300, total: 1_000) == 1)
        #expect(progress.isComplete(total: 1_000))
    }

    @Test("Network policy rejects insecure repository URLs")
    func networkPolicy() {
        #expect(NetworkPolicy.validateHTTPS(URL(string: "https://example.com/feed.json")!))
        #expect(!NetworkPolicy.validateHTTPS(URL(string: "http://example.com/feed.json")!))
        #expect(!NetworkPolicy.validateHTTPS(URL(string: "https://user:pass@example.com/feed.json")!))
        #expect(!NetworkPolicy.validateHTTPS(URL(string: "https://localhost/feed.json")!))
    }

    @Test("Manifest policy binds package, bundle, and version")
    func manifestPolicy() throws {
        let plist: [String: Any] = [
            "items": [[
                "assets": [["kind": "software-package", "url": "http://127.0.0.1:1234/app.ipa"]],
                "metadata": ["bundle-identifier": "com.example.app", "bundle-version": "2"]
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(NetworkPolicy.manifestIsValid(data, packageURL: "http://127.0.0.1:1234/app.ipa", bundleID: "com.example.app", version: "2"))
        #expect(!NetworkPolicy.manifestIsValid(data, packageURL: "http://127.0.0.1:1234/other.ipa", bundleID: "com.example.app", version: "2"))
        #expect(!NetworkPolicy.manifestIsValid(data, packageURL: "http://127.0.0.1:1234/app.ipa", bundleID: "com.other.app", version: "2"))
    }

    @Test("Protected persistence replaces an index atomically")
    func protectedPersistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProtectedPersistence.write(Data("first".utf8), to: url)
        try ProtectedPersistence.write(Data("second".utf8), to: url)
        #expect(try String(contentsOf: url) == "second")
    }

    @Test("AltServer anisette request uses the official length-prefixed message")
    func altServerRequestFrame() throws {
        let frame = try AltServerWireProtocol.anisetteRequestFrame()
        let header = Data(frame.prefix(MemoryLayout<Int32>.size))
        let payload = Data(frame.dropFirst(MemoryLayout<Int32>.size))
        let size = try AltServerWireProtocol.responseSize(from: header)
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        #expect(size == payload.count)
        #expect(json["identifier"] as? String == "AnisetteDataRequest")
        #expect(json["version"] as? Int == 1)
    }

    @Test("AltServer anisette response preserves all Apple headers")
    func altServerAnisetteResponse() throws {
        let payload = Data(#"{"identifier":"AnisetteDataResponse","version":1,"anisetteData":{"X-Mme-Device-Id":"device","X-Apple-I-MD":"otp"}}"#.utf8)
        let anisette = try AltServerWireProtocol.anisetteData(from: payload)

        #expect(anisette["X-Mme-Device-Id"] == "device")
        #expect(anisette["X-Apple-I-MD"] == "otp")
    }

    @Test("AltServer anisette response accepts numeric routingInfo")
    func altServerAnisetteNumericFields() throws {
        let payload = Data(#"{"identifier":"AnisetteDataResponse","version":1,"anisetteData":{"machineID":"mid","oneTimePassword":"otp","routingInfo":17106176}}"#.utf8)
        let anisette = try AltServerWireProtocol.anisetteData(from: payload)

        #expect(anisette["machineID"] == "mid")
        #expect(anisette["routingInfo"] == "17106176")
    }

    @Test("AltServer machineID errors explain the macOS 27 workaround")
    func altServerMachineIDError() throws {
        let payload = Data(#"{"identifier":"ErrorResponse","version":1,"errorCode":1,"errorDescription":"could not retrieve anisette data value machineID"}"#.utf8)
        do {
            _ = try AltServerWireProtocol.anisetteData(from: payload)
            Issue.record("Expected the machineID response to throw")
        } catch let error as AltServerClientError {
            #expect(error.localizedDescription.contains("machineID"))
            #expect(error.localizedDescription.contains("anisette"))
        }
    }

    @Test("Anisette payload maps Apple headers into AltSign JSON keys")
    func anisettePayloadMapsHeaders() throws {
        let json = try #require(AnisettePayload.json(from: [
            "X-Apple-I-MD-M": "machine",
            "X-Apple-I-MD": "otp",
            "X-Apple-I-MD-LU": "local",
            "X-Apple-I-MD-RINFO": "17106176",
            "X-Mme-Device-Id": "device",
            "X-Apple-I-SRL-NO": "serial",
            "X-MMe-Client-Info": "<MacBookPro>",
            "X-Apple-I-Client-Time": "2026-09-05T12:00:00Z",
            "X-Apple-Locale": "en_US",
            "X-Apple-I-TimeZone": "UTC"
        ]))

        #expect(json["machineID"] == "machine")
        #expect(json["oneTimePassword"] == "otp")
        #expect(json["localUserID"] == "local")
        #expect(json["deviceUniqueIdentifier"] == "device")
        #expect(json["deviceSerialNumber"] == "serial")
        #expect(json["deviceDescription"] == "<MacBookPro>")
        #expect(json["date"] == "2026-09-05T12:00:00Z")
    }

    @Test("Remote anisette data uses a coherent iOS 27 client identity")
    func remoteAnisetteUsesCompatibleClientDescription() throws {
        let json = try #require(AnisettePayload.json(
            from: [
                "machineID": "machine",
                "oneTimePassword": "otp",
                "deviceDescription": "<MacBookPro18,3> <macOS;13.4.1;22F82> <com.apple.dt.Xcode/3594.4.19)>"
            ],
            clientDescription: AnisettePayload.compatibilityClientDescription
        ))

        #expect(json["deviceDescription"] == AnisettePayload.compatibilityClientDescription)
    }

    @Test("AltServer keeps the real Mac model and OS build while updating Xcode")
    func altServerKeepsCurrentMacIdentity() {
        let actual = "<Mac17,3> <macOS;27.0;26A5416b> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        let updated = AnisettePayload.clientDescription(forAltServerData: ["deviceDescription": actual])
        #expect(updated == "<Mac17,3> <macOS;27.0;26A5416b> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>")
    }

    @Test("Legacy AltServer identity uses a coherent fallback")
    func altServerLegacyMacIdentity() {
        let legacy = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        #expect(AnisettePayload.clientDescription(forAltServerData: ["deviceDescription": legacy]) ==
                AnisettePayload.compatibilityClientDescription)
    }

    @Test("Apple service failures explain the malformed-response condition")
    func appleServiceUnavailableMessage() {
        let message = AltServerProvisioningError.appleServiceUnavailable("HTTP 503").localizedDescription

        #expect(message.contains("HTTP 503"))
        #expect(message.contains("not a provisioning-profile mismatch"))
    }

    @Test("Manual audit blocks a missing extension profile")
    func provisioningAuditBlocksMissingExtension() {
        let rootProfile = profile(name: "Root", appID: "TEAM.com.resigned.demo",
                                  groups: ["group.resolved.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [rootProfile],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: false,
            deviceIdentifier: "DEVICE"
        )

        #expect(!audit.isReady)
        #expect(audit.rows.last?.state == .missingProfile)
        #expect(audit.firstBlockingMessage(includeNested: false) == nil)
        #expect(audit.selectedProfileIDs == [rootProfile.id])
        // The UI offers "Sign Without App Extensions"; with that on, it signs.
        #expect(audit.onlyExtensionsBlocked)
        let withoutExtensions = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [rootProfile],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: true,
            deviceIdentifier: "DEVICE"
        )
        #expect(!withoutExtensions.onlyExtensionsBlocked)
        #expect(!withoutExtensions.rows.contains { $0.kind != .app && $0.state.isBlocking })
    }

    @Test("A missing IPA fails the install with a reason instead of hanging")
    @MainActor
    func installMissingPackage() {
        let coordinator = InstallCoordinator()
        coordinator.install(ipa: URL(fileURLWithPath: "/tmp/forgesign-missing-\(UUID().uuidString).ipa"),
                            bundleId: "com.example.app", version: "1.0")
        #expect(!coordinator.isInstalling)
        #expect(coordinator.lastError?.contains("no longer in the Library") == true)
    }

    @Test("Wildcard app profiles match their root bundle and descendants")
    func provisioningAuditMatchesWildcardRoot() {
        let wildcardProfile = profile(name: "Wildcard", appID: "TEAM.com.original.demo.*")
        let audit = ProvisioningAuditService.makeAudit(
            inspection: IPAPreflight(
                appName: "Demo", bundleIdentifier: "com.original.demo",
                shortVersion: "1.0", buildVersion: "1", minimumOSVersion: nil,
                nestedBundleCount: 0, extensionCount: 0, frameworkCount: 0,
                watchAppCount: 0, totalMachOCount: 1, signedMachOCount: 0,
                encryptedExecutableCount: 0, encryptedPaths: [],
                bundles: [SignableBundleInspection(
                    path: "/", kind: .app, bundleIdentifier: "com.original.demo",
                    entitlementsAvailable: true, requiredAppGroups: [],
                    requiredKeychainAccessGroups: [])],
                archiveBytes: 1
            ),
            profiles: [wildcardProfile], preferredProfileID: wildcardProfile.id,
            certificate: certificate(), requestedBundleID: "",
            removeExtensions: false, deviceIdentifier: nil
        )

        #expect(audit.isReady)
        #expect(audit.rows.first?.profileID == wildcardProfile.id)
    }

    @Test("A profile with no device list warns instead of green-lighting a known device")
    func provisioningAuditWarnsOnMissingDeviceCoverage() {
        // Same wildcard shape as above but with the device list stripped, the
        // omission ProfileStore.refreshed defends against. With the device
        // known, membership cannot be confirmed.
        let listed = profile(name: "Wildcard", appID: "TEAM.com.original.demo.*")
        let unlisted = ProfileRecord(id: UUID(), filename: listed.filename,
                                     name: listed.name, teamID: listed.teamID,
                                     applicationIdentifier: listed.applicationIdentifier,
                                     notAfter: listed.notAfter, provisionedDeviceCount: 0,
                                     provisionsAllDevices: false, getTaskAllow: listed.getTaskAllow,
                                     profileUUID: listed.profileUUID, provisionedDevices: [],
                                     appGroups: listed.appGroups,
                                     keychainAccessGroups: listed.keychainAccessGroups,
                                     developerCertificateSHA256: listed.developerCertificateSHA256,
                                     profileIsAuthentic: true, addedAt: listed.addedAt)
        func audit(_ profileRecord: ProfileRecord, deviceIdentifier: String?) -> ProvisioningAudit {
            ProvisioningAuditService.makeAudit(
                inspection: IPAPreflight(
                    appName: "Demo", bundleIdentifier: "com.original.demo",
                    shortVersion: "1.0", buildVersion: "1", minimumOSVersion: nil,
                    nestedBundleCount: 0, extensionCount: 0, frameworkCount: 0,
                    watchAppCount: 0, totalMachOCount: 1, signedMachOCount: 0,
                    encryptedExecutableCount: 0, encryptedPaths: [],
                    bundles: [SignableBundleInspection(
                        path: "/", kind: .app, bundleIdentifier: "com.original.demo",
                        entitlementsAvailable: true, requiredAppGroups: [],
                        requiredKeychainAccessGroups: [])],
                    archiveBytes: 1
                ),
                profiles: [profileRecord], preferredProfileID: profileRecord.id,
                certificate: certificate(), requestedBundleID: "",
                removeExtensions: false, deviceIdentifier: deviceIdentifier
            )
        }

        #expect(audit(unlisted, deviceIdentifier: "DEVICE").rows.first?.state == .warning)
        // Without a device identifier the characterized .ready behavior stands.
        #expect(audit(unlisted, deviceIdentifier: nil).isReady)
        #expect(audit(listed, deviceIdentifier: "DEVICE").isReady)
    }

    @Test("One matching wildcard profile can cover an app and its extension")
    func provisioningAuditMatchesWildcardExtension() {
        let wildcardProfile = profile(name: "Wildcard", appID: "TEAM.com.resigned.demo.*",
                                      groups: ["group.resolved.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [wildcardProfile],
            preferredProfileID: wildcardProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: false,
            deviceIdentifier: "DEVICE"
        )

        #expect(audit.isReady)
        #expect(audit.rows.map(\.profileID) == [wildcardProfile.id, wildcardProfile.id])
        #expect(audit.selectedProfileIDs == [wildcardProfile.id])
    }

    @Test("Bundle identifier replacement is limited to the root prefix")
    func bundleIdentifierReplacement() {
        #expect(BundleIdentifierResolver.replacingRootPrefix(
            in: "com.a.extension.com.a",
            originalRoot: "com.a",
            resolvedRoot: "com.b"
        ) == "com.b.extension.com.a")
        #expect(BundleIdentifierResolver.replacingRootPrefix(
            in: "com.ab.child",
            originalRoot: "com.a",
            resolvedRoot: "com.b"
        ) == "com.ab.child")
    }

    @Test("Signing records round-trip install states")
    func signingRecordStateRoundTrip() throws {
        let record = SigningRecord(
            inputName: "Input.ipa",
            outputName: "Input-signed.ipa",
            bundleId: "com.example.app",
            version: "1.0",
            certificateCN: "Test Certificate",
            installState: .installing
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SigningRecord.self, from: data)

        #expect(decoded == record)
        #expect(decoded.installState == .installing)
    }

    @Test("Anisette preference resolves every mode into a source plan")
    func anisettePreferencePlans() throws {
        let automatic = AnisettePreference.plan(mode: .automatic, remoteServerAddress: nil, customURLText: "")
        #expect(!automatic.remoteServers.isEmpty)
        #expect(automatic.remoteServers.count <= AnisettePreference.maximumRemoteAttempts)
        #expect(automatic.useAltServer && automatic.useThisDevice)

        let deviceOnly = AnisettePreference.plan(mode: .thisDevice, remoteServerAddress: nil, customURLText: "")
        #expect(deviceOnly.remoteServers.isEmpty && deviceOnly.customURL == nil)
        #expect(!deviceOnly.useAltServer && deviceOnly.useThisDevice)

        let altServerOnly = AnisettePreference.plan(mode: .altServerOnly, remoteServerAddress: nil, customURLText: "")
        #expect(altServerOnly.useAltServer && !altServerOnly.useThisDevice)

        let custom = AnisettePreference.plan(mode: .customURL, remoteServerAddress: nil,
                                             customURLText: "http://192.168.1.10:6969")
        #expect(custom.customURL?.host == "192.168.1.10")
        #expect(custom.remoteServers.isEmpty)

        let chosen = try #require(RemoteAnisetteCatalog.available().dropFirst().first)
        let remote = AnisettePreference.plan(mode: .remoteServer, remoteServerAddress: chosen.address, customURLText: "")
        #expect(remote.remoteServers.map(\.address) == [chosen.address])
        #expect(remote.useAltServer && remote.useThisDevice)
    }

    @Test("A pre-existing anisette URL upgrades to the custom mode")
    func anisetteLegacyUpgrade() {
        #expect(AnisettePreference.resolvedMode(storedMode: "", legacyCustomURLText: "") == .automatic)
        #expect(AnisettePreference.resolvedMode(storedMode: "", legacyCustomURLText: "http://10.0.0.2:6969") == .customURL)
        #expect(AnisettePreference.resolvedMode(storedMode: "device", legacyCustomURLText: "http://10.0.0.2:6969") == .thisDevice)
        #expect(AnisettePreference.parseURL("ani.example.com") == nil)
        #expect(AnisettePreference.parseURL("https://ani.example.com/")?.host == "ani.example.com")
    }

    @Test("Remote anisette servers reject unusable addresses")
    func remoteServerValidation() throws {
        #expect(RemoteAnisetteServer(name: "Bad", address: "not a url") == nil)
        #expect(RemoteAnisetteServer(name: "Bad", address: "ftp://example.com") == nil)
        let server = try #require(RemoteAnisetteServer(name: "  ", address: "https://ani.example.com/"))
        #expect(server.name == "ani.example.com")
        #expect(server.host == "ani.example.com")
    }

    @Test("Published anisette server lists parse in both shapes")
    func publishedServerListParsing() {
        let wrapped = Data(#"{"servers":[{"name":"A","address":"https://a.example"}]}"#.utf8)
        let bare = Data(#"[{"name":"B","address":"https://b.example"}]"#.utf8)
        #expect(RemoteAnisetteCatalog.servers(fromPublishedList: wrapped)?.map(\.name) == ["A"])
        #expect(RemoteAnisetteCatalog.servers(fromPublishedList: bare)?.map(\.name) == ["B"])
        #expect(RemoteAnisetteCatalog.servers(fromPublishedList: Data("nope".utf8)) == nil)
        #expect(Set(RemoteAnisetteCatalog.available().map(\.address)).count == RemoteAnisetteCatalog.available().count)
    }

    @Test("Anisette identity derives a stable identifier, user ID and device UUID")
    func anisetteIdentityDerivation() throws {
        let bytes = Data((0..<16).map { UInt8($0) })
        let identity = try #require(AnisetteDeviceIdentity(bytes: bytes))
        #expect(identity.identifier == bytes.base64EncodedString())
        #expect(identity.localUserID.count == 64)
        #expect(identity.localUserID == identity.localUserID.uppercased())
        #expect(UUID(uuidString: identity.deviceIdentifier) != nil)
        #expect(identity == AnisetteDeviceIdentity(bytes: bytes))
        #expect(AnisetteDeviceIdentity(bytes: Data([1, 2, 3])) == nil)
        #expect(AnisetteDeviceIdentity.generate() != identity)
    }

    @Test("Remote anisette headers map into the AltSign payload")
    func remoteAnisettePayload() throws {
        let identity = try #require(AnisetteDeviceIdentity(bytes: Data((0..<16).map { UInt8($0) })))
        let json = try #require(RemoteAnisetteClient.anisetteJSON(
            identity: identity,
            machineID: "machine",
            oneTimePassword: "otp",
            routingInfo: "17106176",
            clientInfo: "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        ))
        #expect(json["machineID"] == "machine")
        #expect(json["oneTimePassword"] == "otp")
        #expect(json["routingInfo"] == "17106176")
        #expect(json["localUserID"] == identity.localUserID)
        #expect(json["deviceUniqueIdentifier"] == identity.deviceIdentifier)
        #expect(json["deviceDescription"]?.contains("com.apple.dt.Xcode") == true)
    }

    @Test("Provisioning helpers build valid socket URLs and Apple requests")
    func provisioningRequestHelpers() throws {
        let secure = try #require(URL(string: "https://ani.example.com"))
        #expect(try RemoteAnisetteClient.provisioningSocketURL(from: secure).scheme == "wss")
        let plain = try #require(URL(string: "http://10.0.0.2:6969"))
        #expect(try RemoteAnisetteClient.provisioningSocketURL(from: plain).absoluteString
            == "ws://10.0.0.2:6969/v3/provisioning_session")

        let identity = try #require(AnisetteDeviceIdentity(bytes: Data((0..<16).map { UInt8($0) })))
        let request = RemoteAnisetteClient.appleRequest(
            url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!,
            clientInfo: "<MacBookPro13,2>",
            userAgent: "akd/1.0",
            identity: identity
        )
        #expect(request.value(forHTTPHeaderField: "X-Apple-I-MD-LU") == identity.localUserID)
        #expect(request.value(forHTTPHeaderField: "X-Mme-Device-Id") == identity.deviceIdentifier)
        #expect(request.value(forHTTPHeaderField: "X-Mme-Client-Info") == "<MacBookPro13,2>")

        let body = try RemoteAnisetteClient.plistBody(header: [:], request: ["cpim": "cpim-value"])
        let plist = try #require(try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
        #expect((plist["Request"] as? [String: String])?["cpim"] == "cpim-value")
    }

    @Test("Anisette errors name the failing source")
    func anisetteErrorDescriptions() {
        #expect(RemoteAnisetteError.httpStatus(429, "ani.example.com").localizedDescription.contains("429"))
        #expect(RemoteAnisetteError.unreachable("ani.example.com", "timed out").localizedDescription.contains("ani.example.com"))
        #expect(RemoteAnisetteError.noDataSource.localizedDescription.contains("anisette"))
    }

    @Test("Installation phases report terminal state and labels")
    func installationPhaseSemantics() {
        #expect(InstallationPhase.delivered.isTerminal)
        #expect(InstallationPhase.completed.isTerminal)
        #expect(InstallationPhase.failed("x").isTerminal)
        #expect(InstallationPhase.cancelled.isTerminal)
        #expect(!InstallationPhase.installing(0.5).isTerminal)
        #expect(InstallationPhase.installing(0.5).isActive)
        #expect(!InstallationPhase.awaitingSystem.isTerminal)
        #expect(InstallationPhase.awaitingSystem.isActive)
        #expect(!InstallationPhase.idle.isActive)
        #expect(InstallationPhase.transferring(0.74).label.contains("74"))
    }

    private func rootOnlyInspection() -> IPAPreflight {
        IPAPreflight(
            appName: "Demo", bundleIdentifier: "com.original.demo",
            shortVersion: "1.0", buildVersion: "1", minimumOSVersion: "16.0",
            nestedBundleCount: 0, extensionCount: 0, frameworkCount: 0,
            watchAppCount: 0, totalMachOCount: 1, signedMachOCount: 1,
            encryptedExecutableCount: 0, encryptedPaths: [],
            bundles: [SignableBundleInspection(path: "/", kind: .app,
                                               bundleIdentifier: "com.original.demo",
                                               entitlementsAvailable: true,
                                               requiredAppGroups: [],
                                               requiredKeychainAccessGroups: [])],
            archiveBytes: 1_024
        )
    }

    private func inspectionWithExtension() -> IPAPreflight {
        IPAPreflight(
            appName: "Demo", bundleIdentifier: "com.original.demo",
            shortVersion: "1.0", buildVersion: "1", minimumOSVersion: "16.0",
            nestedBundleCount: 1, extensionCount: 1, frameworkCount: 0,
            watchAppCount: 0, totalMachOCount: 2, signedMachOCount: 2,
            encryptedExecutableCount: 0, encryptedPaths: [],
            bundles: [
                SignableBundleInspection(path: "/", kind: .app,
                                         bundleIdentifier: "com.original.demo",
                                         entitlementsAvailable: true,
                                         requiredAppGroups: ["group.original.shared"],
                                         requiredKeychainAccessGroups: []),
                SignableBundleInspection(path: "PlugIns/Shield.appex", kind: .extension,
                                         bundleIdentifier: "com.original.demo.shield",
                                         entitlementsAvailable: true,
                                         requiredAppGroups: ["group.original.shared"],
                                         requiredKeychainAccessGroups: [])
            ],
            archiveBytes: 1_024
        )
    }

    @Test("A custom bundle ID no profile covers signs the app with the selected profile")
    func customBundleIDFallsBackToSelectedProfile() {
        let selected = profile(name: "Selected", appID: "TEAM.com.original.demo")
        let audit = ProvisioningAuditService.makeAudit(
            inspection: rootOnlyInspection(), profiles: [selected],
            preferredProfileID: selected.id, certificate: certificate(),
            requestedBundleID: "com.forgetest.apple",
            removeExtensions: false, deviceIdentifier: "DEVICE"
        )
        #expect(audit.isReady)
        #expect(audit.usesSelectedProfileFallback)
        #expect(audit.rows.first?.state == .selectedProfileFallback)
        #expect(audit.rows.first?.resolvedBundleID == "com.forgetest.apple")
        #expect(audit.rows.first?.detail.contains("TEAM.com.original.demo") == true)
        // The native signer treats the first supplied profile as the root fallback.
        #expect(audit.selectedProfileIDs == [selected.id])
    }

    @Test("A profile that matches the custom bundle ID wins over the fallback")
    func customBundleIDPrefersMatchingProfile() {
        let selected = profile(name: "Selected", appID: "TEAM.com.original.demo")
        let matching = profile(name: "Matching", appID: "TEAM.com.forgetest.*")
        let audit = ProvisioningAuditService.makeAudit(
            inspection: rootOnlyInspection(), profiles: [selected, matching],
            preferredProfileID: selected.id, certificate: certificate(),
            requestedBundleID: "com.forgetest.apple",
            removeExtensions: false, deviceIdentifier: "DEVICE"
        )
        #expect(audit.isReady)
        #expect(!audit.usesSelectedProfileFallback)
        #expect(audit.selectedProfileIDs == [matching.id])
    }

    @Test("The selected-profile fallback still enforces team, expiry and device checks")
    func customBundleIDFallbackKeepsProfileChecks() {
        let selected = profile(name: "Selected", appID: "TEAM.com.original.demo")
        func audit(certificate: CertificateRecord, device: String) -> ProvisioningAudit {
            ProvisioningAuditService.makeAudit(
                inspection: rootOnlyInspection(), profiles: [selected],
                preferredProfileID: selected.id, certificate: certificate,
                requestedBundleID: "com.forgetest.apple",
                removeExtensions: false, deviceIdentifier: device
            )
        }
        let expired = audit(certificate: certificate(notAfter: .distantPast), device: "DEVICE")
        #expect(!expired.isReady)
        #expect(expired.rows.first?.state == .missingProfile)
        #expect(expired.rows.first?.detail.contains("can't be used instead") == true)
        #expect(expired.selectedProfileIDs.isEmpty)

        let wrongTeam = CertificateRecord(id: UUID(), filename: "other.p12", commonName: "Other",
                                          organization: "Other", teamID: "OTHER",
                                          notAfter: .distantFuture, certificateSHA256: "certificate",
                                          addedAt: .now, hasSavedPassword: false)
        #expect(!audit(certificate: wrongTeam, device: "DEVICE").isReady)
        #expect(!audit(certificate: certificate(), device: "ANOTHER-DEVICE").isReady)
    }

    @Test("Without a custom bundle ID an unrelated selected profile still blocks the app")
    func unchangedBundleIDKeepsRootBlocker() {
        let selected = profile(name: "Selected", appID: "TEAM.com.unrelated.app")
        for requested in ["", "com.original.demo"] {
            let audit = ProvisioningAuditService.makeAudit(
                inspection: rootOnlyInspection(), profiles: [selected],
                preferredProfileID: selected.id, certificate: certificate(),
                requestedBundleID: requested,
                removeExtensions: false, deviceIdentifier: "DEVICE"
            )
            #expect(!audit.isReady)
            #expect(audit.rows.first?.state == .missingProfile)
            #expect(!audit.usesSelectedProfileFallback)
        }
    }

    @Test("The fallback covers only the main app; extensions still need their own profile")
    func customBundleIDFallbackSkipsExtensions() {
        let selected = profile(name: "Selected", appID: "TEAM.com.original.demo",
                               groups: ["group.original.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(), profiles: [selected],
            preferredProfileID: selected.id, certificate: certificate(),
            requestedBundleID: "com.forgetest.apple",
            removeExtensions: false, deviceIdentifier: "DEVICE"
        )
        #expect(!audit.isReady)
        #expect(audit.rows.first?.state == .selectedProfileFallback)
        #expect(audit.rows.last?.state == .missingProfile)
        #expect(audit.onlyExtensionsBlocked)

        let withoutExtensions = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(), profiles: [selected],
            preferredProfileID: selected.id, certificate: certificate(),
            requestedBundleID: "com.forgetest.apple",
            removeExtensions: true, deviceIdentifier: "DEVICE"
        )
        #expect(withoutExtensions.isReady)
        #expect(withoutExtensions.selectedProfileIDs == [selected.id])
    }

    @Test("Removing extensions cannot repair a blocked root app")
    func extensionRecoveryRequiresUsableRoot() {
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(), profiles: [],
            preferredProfileID: nil, certificate: certificate(), requestedBundleID: "",
            removeExtensions: false, deviceIdentifier: "DEVICE"
        )
        #expect(!audit.onlyExtensionsBlocked)
    }

    @Test("The audit omits an unrelated selected root profile")
    func auditUsesMatchingRootProfile() {
        let unrelated = profile(name: "Unrelated", appID: "TEAM.com.other.app")
        let matching = profile(name: "Matching", appID: "TEAM.com.original.*", groups: ["group.original.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(), profiles: [unrelated, matching],
            preferredProfileID: unrelated.id, certificate: certificate(), requestedBundleID: "",
            removeExtensions: false, deviceIdentifier: "DEVICE"
        )
        #expect(audit.isReady)
        #expect(audit.selectedProfileIDs == [matching.id])
    }

    @Test("An expired certificate blocks otherwise compatible profiles")
    func auditRejectsExpiredCertificate() {
        let matching = profile(name: "Matching", appID: "TEAM.com.original.*", groups: ["group.original.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(), profiles: [matching],
            preferredProfileID: matching.id, certificate: certificate(notAfter: .distantPast), requestedBundleID: "",
            removeExtensions: false, deviceIdentifier: "DEVICE"
        )
        #expect(!audit.isReady)
        #expect(audit.rows.first?.state == .expired)
        #expect(audit.rows.first?.detail.contains("certificate") == true)
    }

    private func certificate(notAfter: Date = .distantFuture) -> CertificateRecord {
        CertificateRecord(id: UUID(), filename: "test.p12", commonName: "Test",
                          organization: "Test", teamID: "TEAM", notAfter: notAfter,
                          certificateSHA256: "certificate", addedAt: .now,
                          hasSavedPassword: false)
    }

    private func profile(name: String, appID: String, groups: [String] = []) -> ProfileRecord {
        ProfileRecord(id: UUID(), filename: "\(name).mobileprovision", name: name,
                      teamID: "TEAM", applicationIdentifier: appID,
                      notAfter: .distantFuture, provisionedDeviceCount: 1,
                      provisionsAllDevices: false, getTaskAllow: true,
                      profileUUID: UUID().uuidString, provisionedDevices: ["DEVICE"],
                      appGroups: groups, keychainAccessGroups: [],
                      developerCertificateSHA256: ["certificate"],
                      profileIsAuthentic: true, addedAt: .now)
    }
}

// MARK: - Refresh (Phase 6)

@Suite("Refresh planning")
struct RefreshPlanningTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Refresh window opens 48h before expiry")
    func refreshWindow() {
        #expect(RefreshPlanner.shouldRefresh(expiry: now.addingTimeInterval(47 * 3600), now: now))
        #expect(RefreshPlanner.shouldRefresh(expiry: now.addingTimeInterval(-60), now: now), "expired apps stay due")
        #expect(!RefreshPlanner.shouldRefresh(expiry: now.addingTimeInterval(49 * 3600), now: now))
        #expect(!RefreshPlanner.shouldRefresh(expiry: nil, now: now), "an unknown expiry is not a due date")
    }

    @Test("Expiry text is human and never negative")
    func expiryText() {
        #expect(RefreshPlanner.expiryText(now.addingTimeInterval(2 * 86_400 + 7 * 3_600), now: now) == "Expires in 2d 7h")
        #expect(RefreshPlanner.expiryText(now.addingTimeInterval(3 * 3_600), now: now) == "Expires in 3h")
        #expect(RefreshPlanner.expiryText(now.addingTimeInterval(600), now: now) == "Expires today")
        #expect(RefreshPlanner.expiryText(now.addingTimeInterval(-3 * 86_400), now: now) == "Expired 3d ago")
        #expect(RefreshPlanner.expiryText(nil) == nil)
    }

    @Test("Capability names the first missing input")
    func capability() {
        let complete = RefreshInputs(hasRefreshSource: true, hasCertificatePassword: true,
                                     hasAppleAccount: true, hasInstallTransport: true,
                                     profileExpiresAt: now.addingTimeInterval(10 * 86_400))
        #expect(RefreshPlanner.capability(for: complete, now: now).isAutomatic)

        var noTransport = complete
        noTransport.hasInstallTransport = false
        #expect(RefreshPlanner.capability(for: noTransport, now: now) == .unsupported(reason: "No installation transport is available in this build."))

        var noSource = complete
        noSource.hasRefreshSource = false
        #expect(RefreshPlanner.capability(for: noSource, now: now).label == "action needed")

        var noPassword = complete
        noPassword.hasCertificatePassword = false
        #expect(RefreshPlanner.capability(for: noPassword, now: now).label == "action needed")

        var expired = complete
        expired.profileExpiresAt = now.addingTimeInterval(-3600)
        #expect(RefreshPlanner.capability(for: expired, now: now).label == "action needed")
    }

    @Test("Scan lists due apps oldest first and summarises")
    func scan() {
        let soon = SigningRecord(inputName: "a.ipa", outputName: "a.ipa", bundleId: "a",
                                 version: "1", certificateCN: nil,
                                 profileExpiresAt: now.addingTimeInterval(3_600))
        let later = SigningRecord(inputName: "b.ipa", outputName: "b.ipa", bundleId: "b",
                                  version: "1", certificateCN: nil,
                                  profileExpiresAt: now.addingTimeInterval(30 * 3_600))
        let distant = SigningRecord(inputName: "c.ipa", outputName: "c.ipa", bundleId: "c",
                                    version: "1", certificateCN: nil,
                                    profileExpiresAt: now.addingTimeInterval(60 * 86_400))

        let result = RefreshScanner.scan([later, distant, soon], now: now)
        #expect(result.due == [soon.id, later.id])
        #expect(result.summary == "2 apps expire within 48h")
        #expect(RefreshScanner.scan([distant], now: now).summary == nil)
    }

    @Test("Library entries written before refresh metadata still decode")
    func legacyRecordDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","date":1700000000,"inputName":"in.ipa","outputName":"out.ipa",\
        "bundleId":"com.example.app","version":"1.0","certificateCN":"CN","installState":"signed"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(SigningRecord.self, from: Data(legacy.utf8))
        #expect(record.profileExpiresAt == nil)
        #expect(record.refreshSourceName == nil)
        #expect(record.signedCopyRemovedAt == nil)
        #expect(record.installState == .signed)
    }
}

@Suite("Library storage cleanup")
@MainActor
struct LibraryStorageCleanupTests {
    @Test("Delivered cleanup preserves history and leaves unsigned install attempts")
    func deliveredCopies() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let history = HistoryStore(baseDirectory: base)
        let delivered = history.append(inputName: "delivered.ipa", outputName: "delivered-signed.ipa",
                                       bundleId: "com.example.delivered", version: "1", certificateCN: nil)
        let waiting = history.append(inputName: "waiting.ipa", outputName: "waiting-signed.ipa",
                                     bundleId: "com.example.waiting", version: "1", certificateCN: nil)
        try Data(repeating: 0x41, count: 2_000).write(to: history.outputURL(for: delivered))
        try Data(repeating: 0x42, count: 3_000).write(to: history.outputURL(for: waiting))
        history.setInstallState(.delivered, for: delivered.id)

        #expect(history.signedCopyBytes == 5_000)
        #expect(history.deliveredCopyBytes == 2_000)
        let result = history.clearSignedCopies(deliveredOnly: true)
        #expect(result.removed == 1 && result.failed == 0)
        #expect(!FileManager.default.fileExists(atPath: history.outputURL(for: delivered).path))
        #expect(FileManager.default.fileExists(atPath: history.outputURL(for: waiting).path))
        #expect(history.records.count == 2)
        #expect(history.records.first(where: { $0.id == delivered.id })?.signedCopyRemovedAt != nil)
        #expect(history.records.first(where: { $0.id == waiting.id })?.signedCopyRemovedAt == nil)

        let reopened = HistoryStore(baseDirectory: base)
        #expect(reopened.records.count == 2)
        #expect(reopened.records.first(where: { $0.id == delivered.id })?.signedCopyRemovedAt != nil)
        #expect(reopened.signedCopyBytes == 3_000)

        let rest = reopened.clearSignedCopies(deliveredOnly: false)
        #expect(rest.removed == 1 && rest.failed == 0)
        #expect(reopened.signedCopyBytes == 0)
        #expect(reopened.records.count == 2)
        #expect(reopened.delete(waiting))
        #expect(reopened.records.count == 1)
    }

    @Test("Download cleanup waits for the Sign handoff and keeps repository metadata")
    func repositoryDownloads() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = RepositoryStore(baseDirectory: base)
        _ = store.add(urlString: "https://example.com/apps.json")
        let ipa = base.appendingPathComponent("Downloads/app.ipa")
        try Data(repeating: 0x41, count: 4_096).write(to: ipa)
        #expect(store.downloadedBytes == 4_096)

        store.pendingIPA = ipa
        #expect(store.clearDownloads().removed == 0)
        #expect(FileManager.default.fileExists(atPath: ipa.path))

        store.pendingIPA = nil
        let result = store.clearDownloads()
        #expect(result.removed == 1 && result.failed == 0)
        #expect(store.downloadedBytes == 0)
        #expect(store.repositories.count == 1)
    }

    @Test("Staging cleanup waits for inspection and resets the selected input")
    func stagedInput() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("source.ipa")
        try Data(repeating: 0x41, count: 1_024).write(to: source)
        let signer = SigningService(workDirectory: base.appendingPathComponent("work"))
        let staged = try await signer.stage(source)
        #expect(signer.stagedBytes == 1_024)

        signer.beginInputCheck()
        #expect(signer.clearStaging().removed == 0)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        signer.endInputCheck()
        #expect(signer.clearStaging().removed == 1)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(signer.stagedBytes == 0)
        #expect(signer.stagingResetID == 1)
    }
}

@Suite("Refresh sources")
@MainActor
struct RefreshSourceStoreTests {
    @Test("A Library refresh carries the installed bundle ID and original name")
    func refreshRouting() {
        let router = ImportRouter()
        let kept = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).ipa")
        router.receiveRefresh(kept, bundleID: "com.example.app", name: "Example.ipa")
        #expect(router.consume() == .refresh(kept, bundleID: "com.example.app", name: "Example.ipa"))
        #expect(router.consume() == nil)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func package(named name: String, bytes: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("Clearing kept originals removes stored and orphaned copies")
    func removeAllStoredCopies() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("kept", isDirectory: true)
        let store = RefreshSourceStore(directory: directory)
        let original = try package(named: "original.ipa", bytes: 2_048, in: base)
        let id = UUID()
        #expect(await store.retain(original, for: id) != nil)
        let orphan = try package(named: "orphan.ipa", bytes: 512, in: directory)
        #expect(store.storedBytes == 2_560)

        let result = store.removeAll()
        #expect(result.removed == 2 && result.failed == 0)
        #expect(store.storedBytes == 0)
        #expect(store.totalBytes == 0)
        #expect(store.sourceURL(for: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Retaining copies the original and reports it back")
    func retain() async throws {
        let directory = try tempDirectory()
        let store = RefreshSourceStore(directory: directory)
        let id = UUID()
        let original = try package(named: "original.ipa", bytes: 2_048, in: directory)

        let kept = await store.retain(original, for: id)
        #expect(kept == "\(id.uuidString).ipa")
        let url = try #require(store.sourceURL(for: id))
        #expect(try Data(contentsOf: url).count == 2_048)
        #expect(store.sourceName(for: id) == "original.ipa")
        #expect(store.totalBytes == 2_048)

        // The kept copy survives even when the user deletes the original.
        try FileManager.default.removeItem(at: original)
        #expect(store.sourceURL(for: id) != nil)

        store.removeSource(for: id)
        #expect(store.sourceURL(for: id) == nil)
        #expect(store.totalBytes == 0)
    }

    @Test("A package larger than the budget is refused, not silently truncated")
    func refusesOversizedPackage() async throws {
        let directory = try tempDirectory()
        let store = RefreshSourceStore(directory: directory, budget: 1_024)
        let original = try package(named: "big.ipa", bytes: 4_096, in: directory)
        #expect(await store.retain(original, for: UUID()) == nil)
        #expect(store.totalBytes == 0)
    }

    @Test("Pruning evicts the oldest copies to stay inside the budget")
    func prune() async throws {
        let directory = try tempDirectory()
        let store = RefreshSourceStore(directory: directory, budget: 3_000)
        let first = try package(named: "one.ipa", bytes: 2_000, in: directory)
        let second = try package(named: "two.ipa", bytes: 2_000, in: directory)

        let firstID = UUID()
        let secondID = UUID()
        await store.retain(first, for: firstID)
        await store.retain(second, for: secondID, now: Date().addingTimeInterval(60))

        #expect(store.sourceURL(for: firstID) == nil, "the oldest copy is evicted first")
        #expect(store.sourceURL(for: secondID) != nil)
        #expect(store.totalBytes <= 3_000)
    }
}

@Suite("Audit regressions")
@MainActor
struct AuditRegressionTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Selecting an already staged IPA preserves its bytes")
    func restagingSameFile() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let signer = SigningService(workDirectory: base)
        let input = base.appendingPathComponent("input.ipa")
        let bytes = Data("original input".utf8)
        try bytes.write(to: input)
        #expect(try await signer.stage(input) == input)
        #expect(try Data(contentsOf: input) == bytes)

        let alias = base.appendingPathComponent("alias.ipa")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        #expect(try await signer.stage(alias, as: "input.ipa") == input)
        #expect(try Data(contentsOf: input) == bytes)
    }

    @Test("A failed replacement keeps the previous staged IPA")
    func failedReplacement() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let signer = SigningService(workDirectory: base.appendingPathComponent("work"))
        let original = base.appendingPathComponent("original.ipa")
        try Data("keep me".utf8).write(to: original)
        let staged = try await signer.stage(original, as: "input.ipa")
        await #expect(throws: FileCopyOperation.Failure.unreadable) { try await signer.stage(base.appendingPathComponent("missing.ipa"), as: "input.ipa") }
        #expect(try Data(contentsOf: staged) == Data("keep me".utf8))
        await #expect(throws: FileCopyOperation.Failure.invalidDestination) { try await signer.stage(original, as: "../escaped.ipa") }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escaped.ipa").path))
    }

    @Test("Staging refuses to overwrite inputs owned by an active operation")
    func stagingDuringOperation() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let signer = SigningService(workDirectory: base.appendingPathComponent("work"))
        let input = base.appendingPathComponent("input.ipa")
        try Data("first".utf8).write(to: input)
        let staged = try await signer.stage(input)
        try Data("replacement".utf8).write(to: input)
        for phase in [SigningService.Phase.signing, .provisioning] {
            signer.phase = phase
            #expect(!signer.canAcceptInput)
            await #expect(throws: FileCopyOperation.Failure.busy) { try await signer.stage(input) }
            #expect(try Data(contentsOf: staged) == Data("first".utf8))
        }
        signer.phase = .idle
        signer.beginInputCheck()
        await #expect(throws: FileCopyOperation.Failure.busy) { try await signer.stage(input) }
        signer.endInputCheck()
        #expect(try await signer.stage(input) == staged)
        #expect(try Data(contentsOf: staged) == Data("replacement".utf8))
    }

    @Test("Incomplete or encrypted preflight blocks signing")
    func preflightReadiness() {
        #expect(IPAPreflightState.idle.signingBlocker != nil)
        #expect(IPAPreflightState.inspecting.signingBlocker != nil)
        #expect(IPAPreflightState.failed("Invalid archive").signingBlocker == "Invalid archive")
        for encryptedCount in [0, 1] {
            let inspection = IPAPreflight(
                appName: "Demo", bundleIdentifier: "com.example.demo",
                shortVersion: "1", buildVersion: "1", minimumOSVersion: "16.0",
                nestedBundleCount: 0, extensionCount: 0, frameworkCount: 0,
                watchAppCount: 0, totalMachOCount: 1, signedMachOCount: 0,
                encryptedExecutableCount: encryptedCount, encryptedPaths: [],
                bundles: [], archiveBytes: 1
            )
            #expect((IPAPreflightState.ready(inspection).signingBlocker == nil) == (encryptedCount == 0))
        }
    }

    @Test("An install manifest must identify exactly one package and its version")
    func manifestAmbiguity() throws {
        let package = "http://127.0.0.1:1234/app.ipa"
        let asset: [String: Any] = ["kind": "software-package", "url": package]
        let metadata: [String: Any] = ["bundle-identifier": "com.example.app", "bundle-version": "2"]
        let valid: [String: Any] = ["assets": [asset], "metadata": metadata]
        let missingVersion: [String: Any] = ["assets": [asset], "metadata": ["bundle-identifier": "com.example.app"]]
        let extraPackage: [String: Any] = ["assets": [asset, asset], "metadata": metadata]
        for items in [[missingVersion], [valid, valid], [extraPackage]] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["items": items], format: .xml, options: 0)
            #expect(!NetworkPolicy.manifestIsValid(data, packageURL: package, bundleID: "com.example.app", version: "2"))
        }
    }

    @Test("Repository names and versions cannot escape the download directory", arguments: [
        ("Example", "1.2"), ("../Example", "../../outside"),
        ("A/B\\C:D", "1/2:3"), (String(repeating: "📦", count: 300), "1")
    ])
    func repositoryFilename(name: String, version: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "version": version])
        let app = try JSONDecoder().decode(RepoApp.self, from: data)
        let filename = RepositoryStore.ipaName(for: app)
        let directory = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let result = directory.appendingPathComponent(filename).standardizedFileURL
        #expect(result.deletingLastPathComponent() == directory)
        #expect(filename.utf8.count <= 184)
        #expect(result.pathExtension == "ipa")
        #expect(!filename.contains(":"))
        #expect(!filename.contains("\\"))
        if name == "Example" { #expect(filename == "Example-1.2.ipa") }
    }

    @Test("Interrupted installs reopen as retryable signed copies")
    func interruptedInstall() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let history = HistoryStore(baseDirectory: base)
        let record = history.append(inputName: "input.ipa", outputName: "signed.ipa",
                                    bundleId: "com.example.app", version: "1", certificateCN: nil)
        try Data("signed".utf8).write(to: history.outputURL(for: record))
        history.setInstallState(.installing, for: record.id)
        let reopened = HistoryStore(baseDirectory: base)
        #expect(reopened.records.first?.installState == .signed)
        #expect(reopened.fileExists(for: record))
        #expect(HistoryStore(baseDirectory: base).records.first?.installState == .signed)
    }

    @Test("Cancelling an install restores its Library state before any network work")
    func cancelledInstall() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let ipa = base.appendingPathComponent("app.ipa")
        try Data("fixture".utf8).write(to: ipa)
        let recordID = UUID()
        let observed = InstallStateCapture()
        let observer = NotificationCenter.default.addObserver(forName: .forgeInstallState, object: nil, queue: nil) { notification in
            guard notification.userInfo?["recordID"] as? UUID == recordID,
                  let state = notification.userInfo?["state"] as? String else { return }
            MainActor.assumeIsolated { observed.states.append(state) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let coordinator = InstallCoordinator()
        coordinator.install(ipa: ipa, bundleId: "com.example.app", version: "1", recordID: recordID)
        coordinator.cancel()
        #expect(coordinator.phase == .cancelled)
        #expect(observed.states == ["installing", "signed"])
    }
}

@MainActor
private final class InstallStateCapture {
    var states: [String] = []
}
