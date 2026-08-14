import Foundation
import Testing
@testable import ForgeSignUISim

@Suite("Mobile characterization")
struct MobileCharacterizationTests {
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

    @Test("Compatibility accepts an explicit matching profile")
    func explicitProfileCompatibility() {
        let inspection = IPAPreflight(
            appName: "Example",
            bundleIdentifier: "com.example.app",
            shortVersion: "1.0",
            buildVersion: "1",
            minimumOSVersion: "16.0",
            nestedBundleCount: 0,
            extensionCount: 0,
            frameworkCount: 0,
            watchAppCount: 0,
            totalMachOCount: 1,
            signedMachOCount: 1,
            encryptedExecutableCount: 0,
            encryptedPaths: [],
            archiveBytes: 100
        )
        let certificate = CertificateRecord(
            id: UUID(), filename: "cert.p12", commonName: "Test", organization: "Org",
            teamID: "TEAM", notAfter: .now.addingTimeInterval(3600), addedAt: .now,
            hasSavedPassword: false
        )
        let profile = ProfileRecord(
            id: UUID(), filename: "profile.mobileprovision", name: "Profile", teamID: "TEAM",
            applicationIdentifier: "TEAM.com.example.app", notAfter: .now.addingTimeInterval(3600),
            provisionedDeviceCount: 1, provisionsAllDevices: false, getTaskAllow: true,
            profileIsAuthentic: true, addedAt: .now
        )

        #expect(SigningCompatibility.issues(inspection: inspection, certificate: certificate, profile: profile, bundleID: "").isEmpty)
    }

    @Test("Compatibility rejects an uncovered bundle ID")
    func uncoveredBundleID() {
        let profile = ProfileRecord(
            id: UUID(), filename: "profile.mobileprovision", name: "Profile", teamID: "TEAM",
            applicationIdentifier: "TEAM.com.example.app", notAfter: .now.addingTimeInterval(3600),
            provisionedDeviceCount: 1, provisionsAllDevices: false, getTaskAllow: true,
            profileIsAuthentic: true, addedAt: .now
        )
        let issues = SigningCompatibility.issues(
            inspection: nil,
            certificate: nil,
            profile: profile,
            bundleID: "com.other.app"
        )
        #expect(issues.contains { $0.contains("inspection") })
    }

    @Test("Compatibility blocks encrypted or nested targets")
    func encryptedAndNestedTargets() {
        let inspection = IPAPreflight(
            appName: "Example", bundleIdentifier: "com.example.app", shortVersion: "1.0", buildVersion: "1",
            minimumOSVersion: nil, nestedBundleCount: 1, extensionCount: 1, frameworkCount: 0, watchAppCount: 0,
            totalMachOCount: 2, signedMachOCount: 2, encryptedExecutableCount: 1, encryptedPaths: ["Payload/Example.app/Example"], archiveBytes: 100
        )
        let issues = SigningCompatibility.issues(inspection: inspection, certificate: nil, profile: nil, bundleID: "")
        #expect(issues.contains { $0.contains("encrypted") })
        #expect(issues.contains { $0.contains("extensions") })
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
}
