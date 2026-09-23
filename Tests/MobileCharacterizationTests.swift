import Foundation
import Testing
@testable import ForgeSignUISim

@Suite("Mobile characterization")
struct MobileCharacterizationTests {
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
        let message = AltServerProvisioningError.appleServiceUnavailable.localizedDescription

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

    @Test("Automatic installation prefers the most private working method")
    func installationSelectionPrefersLocal() {
        let all: [InstallationBackendSelection.Candidate] = [
            .init(method: .directDevice, availability: .available),
            .init(method: .remoteAltServer, availability: .available),
            .init(method: .ota, availability: .available)
        ]
        #expect(resolvedSelection(.automatic, all) == .directDevice)

        var noPairing = all
        noPairing[0] = .init(method: .directDevice, availability: .requiresPairing)
        #expect(resolvedSelection(.automatic, noPairing) == .remoteAltServer)

        var otaOnly = noPairing
        otaOnly[1] = .init(method: .remoteAltServer, availability: .requiresRemoteServer)
        #expect(resolvedSelection(.automatic, otaOnly) == .ota)
    }

    @Test("An explicit installation method is honoured or refused with a reason")
    func installationSelectionExplicit() {
        let all: [InstallationBackendSelection.Candidate] = [
            .init(method: .directDevice, availability: .available),
            .init(method: .ota, availability: .available)
        ]
        #expect(resolvedSelection(.ota, all) == .ota)

        let otaOnly: [InstallationBackendSelection.Candidate] = [.init(method: .ota, availability: .available)]
        #expect(resolvedSelection(.directDevice, otaOnly) == nil)
        #expect(resolvedSelection(.remoteAltServer, otaOnly) == nil)
        #expect(resolvedSelection(.automatic, []) == nil)

        guard case .failure(let error)? = try? InstallationBackendSelection.resolve(preferred: .directDevice,
                                                                                   candidates: otaOnly) else {
            Issue.record("Expected a refusal for an unavailable explicit method")
            return
        }
        #expect(error.localizedDescription.contains("Direct Device"))
    }

    @Test("Failed methods report usable fallbacks in preference order")
    func installationFallbacks() {
        let candidates: [InstallationBackendSelection.Candidate] = [
            .init(method: .directDevice, availability: .requiresPairing),
            .init(method: .remoteAltServer, availability: .available),
            .init(method: .ota, availability: .available)
        ]
        #expect(InstallationBackendSelection.fallbacks(after: .directDevice, candidates: candidates) == [.remoteAltServer, .ota])
        #expect(InstallationBackendSelection.fallbacks(after: .remoteAltServer, candidates: candidates) == [.ota])
        #expect(InstallationBackendSelection.fallbacks(after: .ota, candidates: candidates) == [.remoteAltServer])

        let otaOnly: [InstallationBackendSelection.Candidate] = [.init(method: .ota, availability: .available)]
        #expect(InstallationBackendSelection.fallbacks(after: .ota, candidates: otaOnly).isEmpty)
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

    @Test("Only a device-confirmed install may read installed")
    @MainActor
    func installationLibraryMapping() {
        #expect(InstallCoordinator.libraryState(for: .deliveredToSystem) == .delivered)
        #expect(InstallCoordinator.libraryState(for: .installed) == .installed)
    }

    @Test("The shipped transports match the feature flags")
    @MainActor
    func installationBackendRegistry() throws {
        let coordinator = InstallCoordinator()
        // directDeviceInstall is ON: the idevice transport is compiled in and
        // hardware validation is in progress. OTA remains the default method.
        #expect(coordinator.availableMethods.contains(.ota))
        if FeatureFlags.directDeviceInstall {
            #expect(coordinator.availableMethods.contains(.directDevice))
        } else {
            #expect(coordinator.availableMethods == [.ota])
        }
        #expect(coordinator.method == .automatic)
        #expect(!coordinator.isInstalling)

        let missing = SignedAppMetadata(ipaURL: URL(fileURLWithPath: "/tmp/forgesign-missing-\(UUID().uuidString).ipa"),
                                        bundleIdentifier: "com.example.app",
                                        version: "1.0",
                                        displayName: "Example")
        guard case .unavailable(let reason)? = coordinator.availability(for: missing).first?.availability else {
            Issue.record("Expected the OTA backend to refuse a missing package")
            return
        }
        #expect(!reason.isEmpty)

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("forgesign-install-\(UUID().uuidString).ipa")
        try Data("ipa".utf8).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let present = SignedAppMetadata(ipaURL: staged, bundleIdentifier: "com.example.app",
                                        version: "1.0", displayName: "Example")
        // In the simulator build the direct transport honestly reports
        // itself unavailable (no FFI linked); OTA must always be available.
        #expect(coordinator.availability(for: present).contains { $0.availability == .available })
    }

    @Test("Device installation errors explain themselves")
    func deviceInstallErrorDescriptions() {
        let errors: [DeviceInstallError] = [.pairingMissing, .pairingInvalid, .pairingDeviceMismatch,
                                            .tunnelUnavailable, .deviceUnavailable, .serviceDiscoveryFailed,
                                            .stagingFailed, .transferFailed, .installRejected(""),
                                            .upgradeRejected(""), .connectionLost, .remoteServerUnavailable,
                                            .remoteServerIncompatible, .unsupportedOS,
                                            .backendUnavailable("nope"), .unverifiedPackage, .cancelled]
        for error in errors {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("Experimental installation transports stay behind flags")
    func featureFlagDefaults() {
        // remoteAltServerInstall stays off: no honest implementation exists.
        // directDeviceInstall is on while the transport is validated on
        // hardware; flipping it back off hides the direct transport again.
        #expect(!FeatureFlags.remoteAltServerInstall)
    }

    @Test("OTA failure messages lose the legacy prefix")
    @MainActor
    func otaFailureMessageCleaning() {
        #expect(OTAInstallationBackend.clean("Install failed: Local install server failed self-check.")
            == "Local install server failed self-check.")
        #expect(OTAInstallationBackend.clean("Cancelled") == "Cancelled")
    }

    @Test("Pairing records parse, validate and reject malformed files")
    func pairingRecordParsing() throws {
        let valid = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        #expect(valid.udid == "00008110-000E34240250201E")
        #expect(valid.hostID == "HOST-1")
        #expect(valid.deviceCertificateFingerprint?.count == 16)
        #expect(valid.byteCount > 0)

        let missingKey = try pairingRecordData(omitting: "HostPrivateKey")
        guard case .failure(.missingField(let field))? = try? DevicePairingRecord.parse(data: missingKey) else {
            Issue.record("Expected a missing-field failure")
            return
        }
        #expect(field == "HostPrivateKey")

        guard case .failure(.unusableUDID)? = try? DevicePairingRecord.parse(data: pairingRecordData(udid: "not-a-udid")) else {
            Issue.record("Expected an unusable-UDID failure")
            return
        }
        guard case .failure(.notAPairingRecord)? = try? DevicePairingRecord.parse(data: Data("hello".utf8)) else {
            Issue.record("Expected a not-a-pairing-record failure")
            return
        }

        #expect(DevicePairingRecord.isPlausibleUDID("00008110-000E34240250201E"))
        #expect(DevicePairingRecord.isPlausibleUDID(String(repeating: "a", count: 40)))
        #expect(!DevicePairingRecord.isPlausibleUDID("00008110"))
        #expect(!DevicePairingRecord.isPlausibleUDID(""))
    }

    @Test("AltStore remote-pairing records parse without a UDID")
    func remotePairingRecordParsing() throws {
        // AltStore 2.x / SideStore ALTPairingFile: ed25519 keys, identifier,
        // no UDID — the device identity is learned from the tunnel session.
        let record = try PropertyListSerialization.data(
            fromPropertyList: [
                "public_key": Data(repeating: 1, count: 32),
                "private_key": Data(repeating: 2, count: 32),
                "identifier": "93029d27-d2db-355a-84cb-b88bc77d6008"
            ] as [String: Any], format: .xml, options: 0)
        let parsed = try #require(try? DevicePairingRecord.parse(data: record).get())
        #expect(parsed.kind == .remotePairing)
        #expect(parsed.udid == "rppairing-93029d27-d2db-355a-84cb-b88bc77d6008")
        #expect(parsed.displayName == "Paired over remote pairing")
    }

    @Test("Host-side idevice pair records parse with the UDID from the filename")
    func hostSidePairingRecordParsing() throws {
        // `idevice pair` / pair_host write no UDID key inside the plist — the
        // UDID is the filename — and omit the device-side certificate fields.
        let full = try PropertyListSerialization.propertyList(from: pairingRecordData(), options: [], format: nil) as! [String: Any]
        let hostSide = full.filter { $0.key != "UDID" && $0.key != "DeviceCertificate" && $0.key != "HostCertificate" }
        let hostData = try PropertyListSerialization.data(fromPropertyList: hostSide, format: .xml, options: 0)

        let parsed = try #require(try? DevicePairingRecord.parse(data: hostData, filenameHint: "00008110-000E34240250201E.mobiledevicepairing").get())
        #expect(parsed.udid == "00008110-000E34240250201E")
        #expect(parsed.hostID == "HOST-1")

        // No UDID key and no usable filename hint → honest rejection.
        guard case .failure(.missingField("UDID"))? = try? DevicePairingRecord.parse(data: hostData) else {
            Issue.record("Expected a missing-UDID failure for an anonymous host record")
            return
        }
    }

    @Test("Saving the same record twice updates instead of deadlocking or duplicating")
    @MainActor
    func pairingStoreReimport() throws {
        // Regression: the Keychain store's save() used to call remove() while
        // holding the same non-recursive lock, deadlocking the import path on
        // device. The in-memory double never nested, so tests stayed green.
        // A store that can't re-save would hang here, not fail.
        // The simulator host app is unsigned, so the Keychain can refuse with
        // errSecMissingEntitlement (-34018) — skip the storage assertions there.
        // The deadlock regression itself is proven by completing at all: the
        // old code hung forever on the second save.
        let store = KeychainDevicePairingStore()
        let first = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        do {
            try store.save(first)
            try store.save(first)  // re-import / refreshed payload
            #expect(store.records().count == 1)
            store.remove(udid: first.udid)
            #expect(store.records().isEmpty)
        } catch DevicePairingError.storageFailed {
            // Keychain unavailable in this environment; deadlock check still ran.
        }
    }

    @Test("The pairing store round-trips records and never duplicates a UDID")
    func pairingStoreRoundTrip() throws {
        let store = InMemoryDevicePairingStore()
        let first = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        let second = try #require(try? DevicePairingRecord.parse(data: pairingRecordData(udid: String(repeating: "b", count: 40))).get())

        try store.save(first)
        try store.save(second)
        #expect(store.records().count == 2)

        try store.save(first)
        #expect(store.records().count == 2)

        store.remove(udid: first.udid)
        #expect(store.records().map(\.udid) == [second.udid])
    }

    @Test("Pairing status is honest about what cannot be verified on-device")
    func pairingStatusValidation() throws {
        #expect(DevicePairingValidator.status(records: [], expectedUDID: nil) == .empty)

        let record = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        let matching = DevicePairingValidator.status(records: [record], expectedUDID: record.udid)
        #expect(matching.isUsable)
        #expect(matching.deviceIdentifierMatches == true)

        let mismatch = DevicePairingValidator.status(records: [record], expectedUDID: String(repeating: "c", count: 40))
        #expect(!mismatch.isUsable)
        #expect(mismatch.deviceIdentifierMatches == false)
        #expect(mismatch.summary.contains("another device"))

        let unknown = DevicePairingValidator.status(records: [record], expectedUDID: nil)
        #expect(unknown.isUsable)
        #expect(unknown.deviceIdentifierMatches == nil)
        #expect(unknown.summary.contains("not verifiable"))
    }

    @Test("Tunnel candidates are probed, and the fastest answer wins")
    func tunnelProbing() async {
        let endpoints = [
            DeviceTunnelEndpoint(host: "10.7.0.1", port: 62078, source: .localDevVPN),
            DeviceTunnelEndpoint(host: "127.0.0.1", port: 62078, source: .loopback)
        ]

        let slowOnly = StubProber(reachable: ["10.7.0.1:62078", "127.0.0.1:62078"],
                                  delays: ["10.7.0.1:62078": 0.4, "127.0.0.1:62078": 0.05])
        let fastest = await DeviceTunnelProbe.firstReachable(endpoints: endpoints, prober: slowOnly, timeout: 2)
        #expect(fastest?.host == "127.0.0.1")

        let onlyLoopback = StubProber(reachable: ["127.0.0.1:62078"], delays: [:])
        let loopback = await DeviceTunnelProbe.firstReachable(endpoints: endpoints, prober: onlyLoopback, timeout: 2)
        #expect(loopback?.source == .loopback)

        let nothing = StubProber(reachable: [], delays: [:])
        #expect(await DeviceTunnelProbe.firstReachable(endpoints: endpoints, prober: nothing, timeout: 1) == nil)
        #expect(await DeviceTunnelProbe.firstReachable(endpoints: [], prober: nothing, timeout: 1) == nil)

        let custom = DeviceTunnelCandidates.endpoints(customHost: "192.168.1.44")
        #expect(custom.first?.source == .custom)
        #expect(custom.contains { $0.host == "10.7.0.1" })
        #expect(DeviceTunnelCandidates.endpoints().first?.source == .localDevVPN)
    }

    @Test("Health checks never claim an unimplemented service works")
    func deviceInstallHealthHonesty() {
        let health = DeviceInstallHealthService.makeHealth(
            pairing: .empty,
            tunnel: nil,
            tunnelProbed: true,
            availableMethods: [.ota],
            osVersion: "27.0"
        )
        #expect(health.rows.map(\.id) == ["os", "pairing", "tunnel", "device-service",
                                         "installer-service", "remote", "ota"])
        #expect(health.rows.first(where: { $0.id == "pairing" })?.status == .warning)
        #expect(health.rows.first(where: { $0.id == "tunnel" })?.status == .failed)
        #expect(health.rows.first(where: { $0.id == "device-service" })?.status == .unavailable)
        #expect(health.rows.first(where: { $0.id == "remote" })?.status == .unavailable)
        #expect(health.rows.first(where: { $0.id == "ota" })?.status == .ok)
        #expect(health.summary == "Installation unavailable")

        let unprobed = DeviceInstallHealthService.makeHealth(pairing: .empty, tunnel: nil,
                                                            tunnelProbed: false, availableMethods: [.ota],
                                                            osVersion: "27.0")
        #expect(unprobed.rows.first(where: { $0.id == "tunnel" })?.status == .unknown)

        let reachable = DeviceInstallHealthService.makeHealth(
            pairing: DevicePairingStatus(hasRecord: true, recordValid: true,
                                         deviceIdentifierMatches: true,
                                         connectionReachable: nil, lastValidated: nil),
            tunnel: DeviceTunnelEndpoint(host: "10.7.0.1", port: 62078, source: .localDevVPN),
            tunnelProbed: true,
            availableMethods: [.ota],
            osVersion: "27.0"
        )
        #expect(reachable.rows.first(where: { $0.id == "pairing" })?.status == .ok)
        #expect(reachable.rows.first(where: { $0.id == "tunnel" })?.status == .ok)
    }

    @Test("Diagnostics are redacted: no pairing payloads, keys or full UDIDs")
    func diagnosticsRedaction() throws {
        let store = InMemoryDevicePairingStore()
        let record = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        try store.save(record)
        let pairing = DevicePairingValidator.status(records: store.records(), expectedUDID: record.udid)
        let health = DeviceInstallHealthService.makeHealth(pairing: pairing, tunnel: nil, tunnelProbed: false,
                                                           availableMethods: [.ota], osVersion: "27.0")
        let report = SanitizedDiagnostics.report(health: health, pairing: pairing, records: store.records(),
                                                 availableMethods: [.ota], appVersion: "2.5 (26)",
                                                 osVersion: "27.0", anisetteSource: "Auto")

        #expect(report.contains("ForgeSign 2.5 (26)"))
        #expect(report.contains(SanitizedDiagnostics.mask(udid: record.udid)))
        #expect(!report.contains(record.udid))
        for secret in ["host-private-key-sentinel", "root-private-key-sentinel",
                       "device-certificate-sentinel", "root-certificate-sentinel"] {
            #expect(!report.contains(secret))
        }
        #expect(SanitizedDiagnostics.mask(udid: "short") == "••••")
    }

    @Test("Device installation model imports a record and reports health")
    @MainActor
    func deviceInstallationModelFlow() async throws {
        let store = InMemoryDevicePairingStore()
        let model = DeviceInstallationModel(store: store,
                                            prober: StubProber(reachable: ["10.7.0.1:62078"], delays: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pair-\(UUID().uuidString).mobiledevicepairing")
        try pairingRecordData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        model.importPairing(from: url)
        #expect(store.records().count == 1)
        #expect(model.hasRecord)

        model.refresh(availableMethods: [.ota], expectedUDID: "00008110-000E34240250201E")
        #expect(model.pairing.isUsable)
        #expect(model.health?.rows.first(where: { $0.id == "pairing" })?.status == .ok)
        #expect(model.health?.rows.first(where: { $0.id == "device-service" })?.status == .unavailable)

        await model.runFullCheck(availableMethods: [.ota], expectedUDID: "00008110-000E34240250201E")
        #expect(model.tunnel?.host == "10.7.0.1")

        model.removeAll()
        #expect(!model.hasRecord)
        #expect(store.records().isEmpty)
    }

    private struct StubProber: DevicePortProbing {
        let reachable: Set<String>
        let delays: [String: TimeInterval]

        func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
            let key = "\(host):\(port)"
            if let delay = delays[key] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return reachable.contains(key)
        }
    }

    private func pairingRecordData(udid: String = "00008110-000E34240250201E",
                                   omitting omitted: String? = nil) throws -> Data {
        var plist: [String: Any] = [
            "UDID": udid,
            "HostID": "HOST-1",
            "DeviceCertificate": Data("device-certificate-sentinel".utf8),
            "HostCertificate": Data("host-certificate-sentinel".utf8),
            "HostPrivateKey": Data("host-private-key-sentinel".utf8),
            "RootCertificate": Data("root-certificate-sentinel".utf8),
            "RootPrivateKey": Data("root-private-key-sentinel".utf8),
            "SystemBUID": "BUID-1"
        ]
        plist[omitted ?? ""] = nil
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @Test("Direct install availability gates on pairing, tunnel and transport")
    @MainActor
    func directInstallAvailability() throws {
        let staged = try stagedIPA()
        let app = SignedAppMetadata(ipaURL: staged, bundleIdentifier: "com.example.app",
                                    version: "1.0", displayName: "Example")
        let record = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        let tunnel = DeviceTunnelEndpoint(host: "10.7.0.1", port: 62078, source: .localDevVPN)

        func backend(transport: DeviceTransporting = StubDeviceTransport(),
                     enabled: Bool = true,
                     pairing: [DevicePairingRecord] = [],
                     tunnel: DeviceTunnelEndpoint? = nil,
                     expected: String? = nil) -> DirectDeviceInstallationBackend {
            DirectDeviceInstallationBackend(transport: transport,
                                            isEnabled: enabled,
                                            pairingProvider: { pairing },
                                            tunnelProvider: { tunnel },
                                            expectedUDIDProvider: { expected })
        }

        // The shipped default is disabled, and an unavailable transport says why.
        #expect(backend(enabled: false).availability(for: app)
            == .unavailable(reason: "The paired-device transport is not enabled in this build yet."))
        let unavailable = UnavailableDeviceTransport(reason: "no FFI")
        #expect(backend(transport: unavailable).availability(for: app) == .unavailable(reason: "no FFI"))

        // No pairing record → ask for one; no tunnel → ask for the VPN.
        #expect(backend().availability(for: app) == .requiresPairing)
        #expect(backend(pairing: [record]).availability(for: app) == .requiresVPN)
        #expect(backend(pairing: [record], tunnel: tunnel).availability(for: app) == .available)

        // A record for another device is refused, not silently used.
        #expect(backend(pairing: [record], tunnel: tunnel, expected: String(repeating: "d", count: 40))
            .availability(for: app) == .unavailable(reason: "The stored pairing record belongs to another device."))

        // A missing package is refused before anything touches the device.
        let missing = SignedAppMetadata(ipaURL: URL(fileURLWithPath: "/tmp/forgesign-gone-\(UUID().uuidString).ipa"),
                                        bundleIdentifier: "com.example.app", version: "1.0", displayName: "Example")
        #expect(backend(pairing: [record], tunnel: tunnel).availability(for: missing)
            == .unavailable(reason: "The signed IPA is no longer in the Library."))
    }

    @Test("Direct install reports install vs upgrade honestly")
    @MainActor
    func directInstallUpgradeDecision() async throws {
        let staged = try stagedIPA()
        let app = SignedAppMetadata(ipaURL: staged, bundleIdentifier: "com.example.app",
                                    version: "2.0", displayName: "Example")
        let record = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        let tunnel = DeviceTunnelEndpoint(host: "10.7.0.1", port: 62078, source: .localDevVPN)

        // Fresh install.
        let freshTransport = StubDeviceTransport()
        let freshBackend = DirectDeviceInstallationBackend(transport: freshTransport, isEnabled: true,
                                                           pairingProvider: { [record] },
                                                           tunnelProvider: { tunnel },
                                                           expectedUDIDProvider: { nil })
        var phases: [InstallationPhase] = []
        let freshReceipt = try await freshBackend.install(app) { phases.append($0.phase) }
        #expect(freshReceipt.outcome == .installed)
        #expect(freshReceipt.detail == "Installed on the device.")
        #expect(freshReceipt.method == .directDevice)
        #expect(freshTransport.upgradeFlags == [false])
        #expect(freshTransport.stagedPackages.count == 1)
        #expect(freshTransport.removedPackages == freshTransport.stagedPackages)
        #expect(freshTransport.closedSessions == 1)
        #expect(phases.contains(.connecting))
        #expect(phases.contains(where: { if case .transferring = $0 { return true } else { return false } }))
        #expect(phases.contains(where: { if case .installing = $0 { return true } else { return false } }))
        #expect(phases.contains(.verifying))

        // Already installed → upgrade, never uninstall first.
        let upgradeTransport = StubDeviceTransport()
        upgradeTransport.installed["com.example.app"] = InstalledAppRecord(bundleIdentifier: "com.example.app",
                                                                          version: "1.0", name: "Example")
        let upgradeBackend = DirectDeviceInstallationBackend(transport: upgradeTransport, isEnabled: true,
                                                            pairingProvider: { [record] },
                                                            tunnelProvider: { tunnel },
                                                            expectedUDIDProvider: { nil })
        let upgradeReceipt = try await upgradeBackend.install(app) { _ in }
        #expect(upgradeReceipt.detail?.contains("Upgraded in place") == true)
        #expect(upgradeTransport.upgradeFlags == [true])
    }

    @Test("Direct install failures map to typed errors and clean up staging")
    @MainActor
    func directInstallFailureHandling() async throws {
        let staged = try stagedIPA()
        let app = SignedAppMetadata(ipaURL: staged, bundleIdentifier: "com.example.app",
                                    version: "2.0", displayName: "Example")
        let record = try #require(try? DevicePairingRecord.parse(data: pairingRecordData()).get())
        let tunnel = DeviceTunnelEndpoint(host: "10.7.0.1", port: 62078, source: .localDevVPN)

        func backend(_ transport: StubDeviceTransport) -> DirectDeviceInstallationBackend {
            DirectDeviceInstallationBackend(transport: transport, isEnabled: true,
                                            pairingProvider: { [record] },
                                            tunnelProvider: { tunnel },
                                            expectedUDIDProvider: { nil })
        }

        let failingOpen = StubDeviceTransport()
        failingOpen.failure = .open
        await #expect(throws: DeviceInstallError.connectionLost) {
            try await backend(failingOpen).install(app) { _ in }
        }

        let failingStage = StubDeviceTransport()
        failingStage.failure = .stage
        do {
            _ = try await backend(failingStage).install(app) { _ in }
            Issue.record("Expected a transfer failure")
        } catch let error as DeviceInstallError {
            #expect(error == .transferFailed)
        }

        // A failed upgrade must not leave the staged package behind, and must be
        // reported as an upgrade failure (the installed app is untouched).
        let failingUpgrade = StubDeviceTransport()
        failingUpgrade.installed["com.example.app"] = InstalledAppRecord(bundleIdentifier: "com.example.app",
                                                                        version: "1.0", name: "Example")
        failingUpgrade.failure = .install
        do {
            _ = try await backend(failingUpgrade).install(app) { _ in }
            Issue.record("Expected an upgrade failure")
        } catch let error as DeviceInstallError {
            #expect(error == .upgradeRejected("Device said no."))
        }
        #expect(failingUpgrade.removedPackages == failingUpgrade.stagedPackages)
        #expect(failingUpgrade.closedSessions == 1)

        // Cancellation is reported as cancellation, not as an install failure.
        #expect(DirectDeviceInstallationBackend.map(CancellationError(), upgrade: false) == .cancelled)
        #expect(DirectDeviceInstallationBackend.map(DeviceTransportError.stagingFailed("x"), upgrade: true) == .transferFailed)
        #expect(DirectDeviceInstallationBackend.map(DeviceTransportError.pairingRejected("x"), upgrade: false) == .pairingInvalid)
        #expect(DirectDeviceInstallationBackend.map(DeviceTransportError.serviceUnavailable("x"), upgrade: false) == .deviceUnavailable)
        #expect(DirectDeviceInstallationBackend.map(DeviceTransportError.notAvailable("no FFI"), upgrade: false)
            == .backendUnavailable("no FFI"))
    }

    @Test("The tunnel locator shares the probed endpoint with install backends")
    @MainActor
    func tunnelLocatorSharing() async {
        let store = InMemoryDevicePairingStore()
        let model = DeviceInstallationModel(store: store,
                                            prober: StubProber(reachable: ["10.7.0.1:62078"], delays: [:]))
        DeviceTunnelLocator.shared.update(nil)
        #expect(DeviceTunnelLocator.shared.endpoint == nil)

        await model.runFullCheck(availableMethods: [.ota], expectedUDID: nil)
        #expect(DeviceTunnelLocator.shared.endpoint?.host == "10.7.0.1")
        DeviceTunnelLocator.shared.update(nil)
    }

    private final class StubDeviceTransport: DeviceTransporting, @unchecked Sendable {
        enum Failure { case open, lookup, stage, install }
        var failure: Failure?
        var installed: [String: InstalledAppRecord] = [:]
        private(set) var stagedPackages: [String] = []
        private(set) var removedPackages: [String] = []
        private(set) var upgradeFlags: [Bool] = []
        private(set) var closedSessions = 0

        var isAvailable: Bool { true }
        var unavailableReason: String { "" }

        func openSession(pairing: DevicePairingRecord, tunnel: DeviceTunnelEndpoint) async throws {
            if failure == .open { throw DeviceTransportError.connectionFailed("refused") }
        }

        func closeSession() async { closedSessions += 1 }

        func installedApp(bundleIdentifier: String) async throws -> InstalledAppRecord? {
            if failure == .lookup { throw DeviceTransportError.serviceUnavailable("no service") }
            return installed[bundleIdentifier]
        }

        func stage(package: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
            if failure == .stage { throw DeviceTransportError.transferFailed("disk full") }
            let path = "/PublicStaging/\(package.lastPathComponent)"
            stagedPackages.append(path)
            onProgress(0.5)
            onProgress(1.0)
            return path
        }

        func installStagedPackage(atPath: String,
                                  bundleIdentifier: String,
                                  upgrade: Bool,
                                  onProgress: @escaping @Sendable (Double) -> Void) async throws {
            upgradeFlags.append(upgrade)
            if failure == .install {
                throw upgrade ? DeviceTransportError.upgradeFailed("Device said no.")
                               : DeviceTransportError.installFailed("Device said no.")
            }
            onProgress(1.0)
        }

        func removeStagedPackage(atPath: String) async { removedPackages.append(atPath) }
    }

    private func stagedIPA() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forgesign-direct-\(UUID().uuidString).ipa")
        try Data("ipa".utf8).write(to: url)
        return url
    }

    private func resolvedSelection(_ preferred: InstallationMethod,
                                   _ candidates: [InstallationBackendSelection.Candidate]) -> InstallationMethod? {
        try? InstallationBackendSelection.resolve(preferred: preferred, candidates: candidates).get()
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

    private func certificate() -> CertificateRecord {
        CertificateRecord(id: UUID(), filename: "test.p12", commonName: "Test",
                          organization: "Test", teamID: "TEAM", notAfter: .distantFuture,
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
        #expect(record.installState == .signed)
    }
}

@Suite("Refresh sources")
@MainActor
struct RefreshSourceStoreTests {
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

    @Test("Retaining copies the original and reports it back")
    func retain() throws {
        let directory = try tempDirectory()
        let store = RefreshSourceStore(directory: directory)
        let id = UUID()
        let original = try package(named: "original.ipa", bytes: 2_048, in: directory)

        let kept = store.retain(original, for: id)
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
    func refusesOversizedPackage() throws {
        let directory = try tempDirectory()
        let store = RefreshSourceStore(directory: directory, budget: 1_024)
        let original = try package(named: "big.ipa", bytes: 4_096, in: directory)
        #expect(store.retain(original, for: UUID()) == nil)
        #expect(store.totalBytes == 0)
    }

    @Test("Pruning evicts the oldest copies to stay inside the budget")
    func prune() throws {
        let directory = try tempDirectory()
        let store = RefreshSourceStore(directory: directory, budget: 3_000)
        let first = try package(named: "one.ipa", bytes: 2_000, in: directory)
        let second = try package(named: "two.ipa", bytes: 2_000, in: directory)

        let firstID = UUID()
        let secondID = UUID()
        store.retain(first, for: firstID)
        store.retain(second, for: secondID, now: Date().addingTimeInterval(60))

        #expect(store.sourceURL(for: firstID) == nil, "the oldest copy is evicted first")
        #expect(store.sourceURL(for: secondID) != nil)
        #expect(store.totalBytes <= 3_000)
    }
}
