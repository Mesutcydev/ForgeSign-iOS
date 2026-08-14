import Foundation

struct SigningRecord: Codable, Identifiable, Equatable {
    enum InstallState: String, Codable {
        case signed, installing, delivered, installed, failed
    }

    let id: UUID
    let date: Date
    let inputName: String
    let outputName: String
    let bundleId: String
    let version: String
    let certificateCN: String?
    var installState: InstallState

    init(id: UUID = UUID(), date: Date = .now, inputName: String, outputName: String,
         bundleId: String, version: String, certificateCN: String?,
         installState: InstallState = .signed) {
        self.id = id
        self.date = date
        self.inputName = inputName
        self.outputName = outputName
        self.bundleId = bundleId
        self.version = version
        self.certificateCN = certificateCN
        self.installState = installState
    }
}

/// Persistent library of signed apps (Application Support/Signed + index json).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [SigningRecord] = []

    let signedDir: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        signedDir = base.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: signedDir, withIntermediateDirectories: true)
        indexURL = base.appendingPathComponent("history.json")
        load()
    }

    func outputURL(for record: SigningRecord) -> URL {
        signedDir.appendingPathComponent(record.outputName)
    }

    func uniqueOutputURL(for inputName: String) -> URL {
        let stem = URL(fileURLWithPath: inputName).deletingPathExtension().lastPathComponent
        let base = stem + "-signed"
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let candidate = signedDir.appendingPathComponent(base + suffix + ".ipa")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    func fileExists(for record: SigningRecord) -> Bool {
        FileManager.default.fileExists(atPath: outputURL(for: record).path)
    }

    @discardableResult
    func append(inputName: String, outputName: String, bundleId: String,
                version: String, certificateCN: String?) -> SigningRecord {
        let record = SigningRecord(inputName: inputName, outputName: outputName,
                                   bundleId: bundleId, version: version,
                                   certificateCN: certificateCN)
        records.insert(record, at: 0)
        save()
        return record
    }

    func setInstallState(_ state: SigningRecord.InstallState, for id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].installState = state
        save()
    }

    func delete(_ record: SigningRecord) {
        try? FileManager.default.removeItem(at: outputURL(for: record))
        records.removeAll { $0.id == record.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([SigningRecord].self, from: data) else { return }
        records = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? ProtectedPersistence.write(data, to: indexURL)
        }
    }
}
