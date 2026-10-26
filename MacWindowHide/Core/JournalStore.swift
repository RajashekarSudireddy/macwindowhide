import Darwin
import Foundation

enum JournalChangePhase: String, Codable { case prepared, applied, committed, restoring }

struct JournalChange: Codable, Identifiable {
    var id = UUID()
    var switchID: SwitchID
    var owner: ActionOwner
    var original: ResourceSnapshot
    var applied: ResourceSnapshot?
    var requestedEnabled: Bool
    var phase: JournalChangePhase = .prepared
    var foregroundPID: Int32?
    var context: ActionContext { ActionContext(owner: owner, foregroundPID: foregroundPID) }
}

struct RecordingJournalSession: Codable {
    var id = UUID()
    var startedAt: Date?
    var endsAt: Date?
    var foregroundPID: Int32?
}

struct MutationJournal: Codable {
    var version = 1
    var session: RecordingJournalSession?
    var changes: [JournalChange] = []
    var timers: [String: Date] = [:]
    // Preserve old recovery evidence without running removed integrations.
    var retiredChanges: [JournalChange]?
    var retiredTimers: [String: Date]?
}

/// Small write-ahead journal. A save must finish before its corresponding OS mutation.
final class JournalStore {
    let directory: URL
    let fileURL: URL
    var beforeSave: (() throws -> Void)?

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("Recovery.json")
    }

    func load() throws -> MutationJournal {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return MutationJournal() }
        var journal = try JSONDecoder().decode(MutationJournal.self, from: Data(contentsOf: fileURL))
        guard journal.version == 1 else { throw SwitchError.failed("The recovery journal was created by an unsupported app version.") }
        let allChanges = journal.changes + (journal.retiredChanges ?? [])
        guard Set(allChanges.map(\.id)).count == allChanges.count else {
            throw SwitchError.failed("The recovery journal contains duplicate operations.")
        }
        guard journal.timers.keys.allSatisfy({ SwitchID(rawValue: $0) != nil }) else {
            throw SwitchError.failed("The recovery journal contains an unknown timer.")
        }
        guard (journal.retiredTimers ?? [:]).keys.allSatisfy({ SwitchID(rawValue: $0)?.isRetired == true }),
              (journal.retiredChanges ?? []).allSatisfy({ $0.switchID.isRetired }) else {
            throw SwitchError.failed("The recovery journal contains invalid retired control evidence.")
        }
        let retired = journal.changes.filter { $0.switchID.isRetired }
        if !retired.isEmpty {
            journal.retiredChanges = (journal.retiredChanges ?? []) + retired
            journal.changes.removeAll { $0.switchID.isRetired }
        }
        if let deadline = journal.timers.removeValue(forKey: SwitchID.retiredDoNotDisturb.rawValue) {
            var retiredTimers = journal.retiredTimers ?? [:]
            retiredTimers[SwitchID.retiredDoNotDisturb.rawValue] = deadline
            journal.retiredTimers = retiredTimers
        }
        return journal
    }

    func save(_ journal: MutationJournal) throws {
        try beforeSave?()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        let temporary = directory.appendingPathComponent(".Recovery-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("Create recovery journal") }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError("Write recovery journal") }
                offset += written
            }
        }
        // macOS may not support a full storage flush on every filesystem; fsync is the fallback.
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
            throw posixError("Synchronize recovery journal")
        }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw posixError("Replace recovery journal") }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw posixError("Open recovery directory") }
        defer { Darwin.close(directoryDescriptor) }
        if Darwin.fsync(directoryDescriptor) != 0 && errno != EINVAL && errno != ENOTSUP {
            throw posixError("Synchronize recovery directory")
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}
