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

    @Test("Manual audit warns instead of blocking a missing extension profile")
    func provisioningAuditWarnsForMissingExtensionWhenNotStrict() {
        let rootProfile = profile(name: "Root", appID: "TEAM.com.resigned.demo",
                                  groups: ["group.resolved.shared"])
        let audit = ProvisioningAuditService.makeAudit(
            inspection: inspectionWithExtension(),
            profiles: [rootProfile],
            preferredProfileID: rootProfile.id,
            certificate: certificate(),
            requestedBundleID: "com.resigned.demo",
            removeExtensions: false,
            deviceIdentifier: "DEVICE",
            strictNestedBundles: false
        )

        #expect(audit.isReady)
        #expect(audit.rows.last?.state == .warning)
        #expect(audit.firstBlockingMessage(includeNested: false) == nil)
        #expect(audit.selectedProfileIDs == [rootProfile.id])
    }

    @Test("Diagnostics provide safe user-facing remediation")
    func diagnostics() {
        #expect(ForgeDiagnostic.persistence.errorDescription?.contains("storage") == true)
        #expect(ForgeDiagnostic.network.errorDescription?.contains("response") == true)
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
