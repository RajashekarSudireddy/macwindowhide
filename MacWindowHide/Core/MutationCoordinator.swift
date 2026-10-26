import Combine
import Foundation

enum RecordingPhase: String { case idle, countdown, preparing, active, restoring, recoveryNeeded }

@MainActor final class MutationCoordinator: ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var statuses: [SwitchID: SwitchStatus] = [:]
    @Published var issue: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endsAt: Date?
    @Published private(set) var timers: [SwitchID: Date] = [:]
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var now = Date()

    var isBusy: Bool { operationInFlight || [.countdown, .preparing, .restoring].contains(phase) }
    var isRecording: Bool { phase == .active }
    var recordingRemaining: TimeInterval? { endsAt.map { max(0, $0.timeIntervalSince(now)) } }
    var elapsed: TimeInterval { startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    private let adapters: [SwitchID: any SystemSwitchAdapter]
    private let settings: SettingsStore
    private let store: JournalStore
    private var journal = MutationJournal()
    private var loadFailed = false
    private var operationInFlight = false
    private var countdownToken = UUID()
    private var tickInFlight = false
    private var lastRefresh = Date.distantPast
    private let transient: Set<SwitchID> = [.desktopIcons, .backdrop, .otherApps, .menuBar, .keepAwake, .keyboardLock]
    private let restoresStandaloneSnapshot: Set<SwitchID> = [.alertSounds, .microphone]

    init(adapters: [any SystemSwitchAdapter], settings: SettingsStore, journalStore: JournalStore? = nil) {
        self.adapters = Dictionary(adapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.settings = settings
        store = journalStore ?? JournalStore(directory: settings.directory)
        do {
            journal = try store.load()
            syncPublishedJournal()
            if journal.session != nil || journal.changes.contains(where: { $0.owner == .recording || $0.phase != .committed }) {
                phase = .recoveryNeeded
            }
        } catch {
            loadFailed = true
            phase = .recoveryNeeded
            issue = "Recovery data could not be read. No system changes will be made: \(error.localizedDescription)"
        }
    }

    func remaining(for id: SwitchID) -> TimeInterval? { timers[id].map { max(0, $0.timeIntervalSince(now)) } }

    func startRecording(foregroundPID: Int32? = nil) async {
        guard phase == .idle, !operationInFlight else { return }
        issue = nil
        let selected = orderedRecordingSwitches()
        guard !selected.isEmpty else { issue = "Choose at least one switch in Recording Mode settings."; return }
        operationInFlight = true
        var unavailable: [String] = []
        for id in selected {
            guard let adapter = adapters[id] else { unavailable.append("\(id.title): not installed"); continue }
            if let reason = await adapter.capability().reason { unavailable.append("\(id.title): \(reason)") }
        }
        operationInFlight = false
        guard unavailable.isEmpty else {
            issue = "Recording Mode could not start.\n" + unavailable.joined(separator: "\n")
            await refresh()
            return
        }

        if settings.preferences.countdownEnabled {
            let token = UUID()
            countdownToken = token
            phase = .countdown
            for value in stride(from: 3, through: 1, by: -1) {
                countdownRemaining = value
                do { try await Task.sleep(for: .seconds(1)) }
                catch { if countdownToken == token { phase = .idle; countdownRemaining = 0 }; return }
                guard countdownToken == token, phase == .countdown else { return }
            }
            countdownRemaining = 0
        }
        guard phase == .idle || phase == .countdown else { return }
        operationInFlight = true
        phase = .preparing
        defer { operationInFlight = false }
        journal.session = RecordingJournalSession(foregroundPID: foregroundPID)
        do {
            try persist()
            for id in selected {
                guard let adapter = adapters[id] else { throw SwitchError.unavailable("\(id.title) is unavailable.") }
                // Snapshot immediately before changing this resource, after the countdown.
                let original = try await adapter.snapshot()
                let change = JournalChange(switchID: id, owner: .recording, original: original, requestedEnabled: true, foregroundPID: foregroundPID)
                journal.changes.append(change)
                try persist()
                try await adapter.apply(enabled: true, context: change.context)
                let actual = try await adapter.snapshot()
                try updateChange(change.id, applied: actual, phase: .applied)
            }
            let date = Date()
            journal.session?.startedAt = date
            let minutes = settings.preferences.recordingLimitMinutes
            journal.session?.endsAt = minutes > 0 ? date.addingTimeInterval(Double(minutes) * 60) : nil
            try persist()
            phase = .active
            await updateStatuses()
        } catch {
            let failure = error.localizedDescription
            let errors = await restoreRecordingChanges()
            phase = errors.isEmpty ? .idle : .recoveryNeeded
            issue = "Recording Mode could not start: \(failure)" + (errors.isEmpty ? " All completed changes were restored." : "\n" + errors.joined(separator: "\n"))
        }
    }

    func stopRecording() async {
        if phase == .countdown {
            countdownToken = UUID()
            countdownRemaining = 0
            phase = .idle
            return
        }
        guard !operationInFlight, journal.session != nil || journal.changes.contains(where: { $0.owner == .recording }) else { return }
        operationInFlight = true
        phase = .restoring
        defer { operationInFlight = false }
        let errors = await restoreRecordingChanges()
        phase = errors.isEmpty ? .idle : .recoveryNeeded
        issue = errors.isEmpty ? nil : errors.joined(separator: "\n")
        await processExpiredTimers()
        await updateStatuses()
    }

    func setSwitch(_ id: SwitchID, enabled: Bool, foregroundPID: Int32? = nil) async {
        guard !isBusy, phase != .recoveryNeeded else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        issue = nil
        do { try await performStandalone(id, enabled: enabled, foregroundPID: foregroundPID, manual: true) }
        catch { issue = "\(id.title): \(error.localizedDescription)" }
        await updateStatuses()
    }

    func scheduleAutoOff(_ id: SwitchID, date: Date) async {
        guard id.supportsTimer, !isBusy, phase != .recoveryNeeded, let adapter = adapters[id] else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        do {
            let current = try await adapter.snapshot()
            guard (await adapter.status()).isEnabled else { throw SwitchError.failed("Turn this switch on before adding a timer.") }
            if !journal.changes.contains(where: { $0.switchID == id && $0.owner == .standalone }) {
                journal.changes.append(JournalChange(switchID: id, owner: .standalone, original: current, applied: current, requestedEnabled: true, phase: .committed))
            }
            journal.timers[id.rawValue] = date
            try persist()
        } catch { issue = "The timer could not be saved: \(error.localizedDescription)" }
    }

    func cancelAutoOff(_ id: SwitchID) {
        guard !operationInFlight else { return }
        journal.timers.removeValue(forKey: id.rawValue)
        if !transient.contains(id) && !restoresStandaloneSnapshot.contains(id) {
            journal.changes.removeAll { $0.switchID == id && $0.owner == .standalone && $0.phase == .committed }
        }
        do { try persist() } catch { issue = error.localizedDescription }
    }

    func extendRecording(minutes: Int) {
        guard phase == .active, minutes > 0, !operationInFlight else { return }
        let baseline = max(journal.session?.endsAt ?? Date(), Date())
        journal.session?.endsAt = baseline.addingTimeInterval(Double(minutes) * 60)
        do { try persist() } catch { issue = "The time extension could not be saved: \(error.localizedDescription)" }
    }

    func refresh() async {
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        await updateStatuses()
        var changed = false
        for change in journal.changes where change.applied != nil && change.phase != .restoring {
            guard let adapter = adapters[change.switchID], let applied = change.applied else { continue }
            do {
                if try await !adapter.matches(applied) {
                    // A user or the OS took control. Stop restoring or timing this resource.
                    journal.changes.removeAll { $0.id == change.id }
                    journal.timers.removeValue(forKey: change.switchID.rawValue)
                    changed = true
                }
            } catch { /* An unreadable resource is retained for a later recovery attempt. */ }
        }
        if changed { do { try persist() } catch { issue = error.localizedDescription } }
        lastRefresh = Date()
    }

    func recover() async {
        guard !operationInFlight else { return }
        operationInFlight = true
        phase = .restoring
        defer { operationInFlight = false }
        // Reload the durable state: a previous final save can fail after an OS operation.
        do { journal = try store.load(); loadFailed = false; syncPublishedJournal() }
        catch { phase = .recoveryNeeded; issue = "Recovery data could not be read: \(error.localizedDescription)"; return }
        var errors = await restoreRecordingChanges()
        for change in journal.changes.reversed() where change.owner == .standalone {
            guard let adapter = adapters[change.switchID] else { errors.append("\(change.switchID.title): the recovery adapter is missing."); continue }
            let pendingTimer = journal.timers[change.switchID.rawValue].map { $0 > Date() } ?? false
            do {
                if change.phase == .committed && pendingTimer {
                    if [.keepAwake, .desktopIcons, .backdrop].contains(change.switchID) {
                        try await adapter.apply(enabled: true, context: change.context)
                        try updateChange(change.id, applied: await adapter.snapshot(), phase: .committed)
                    } else if let applied = change.applied, try await !adapter.matches(applied) {
                        journal.changes.removeAll { $0.id == change.id }
                        journal.timers.removeValue(forKey: change.switchID.rawValue)
                        try persist()
                    }
                } else if change.phase == .committed && !transient.contains(change.switchID) {
                    // Expired persistent timers are handled below through their off action.
                    if journal.timers[change.switchID.rawValue] == nil && !restoresStandaloneSnapshot.contains(change.switchID) {
                        journal.changes.removeAll { $0.id == change.id }
                        try persist()
                    }
                } else {
                    try await restoreChange(change)
                    journal.timers.removeValue(forKey: change.switchID.rawValue)
                    try persist()
                }
            } catch { errors.append("\(change.switchID.title): \(error.localizedDescription)") }
        }
        phase = errors.isEmpty ? .idle : .recoveryNeeded
        if errors.isEmpty { await processExpiredTimers() }
        issue = errors.isEmpty ? nil : "Some changes still need recovery:\n" + errors.joined(separator: "\n")
        await updateStatuses()
    }

    func tick() async {
        now = Date()
        guard !tickInFlight, !isBusy, phase != .recoveryNeeded else { return }
        // System queries are needed only while a recording or an auto-off timer is owned.
        guard phase == .active || !timers.isEmpty else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        if phase == .active, let endsAt, endsAt <= now { await stopRecording(); return }
        operationInFlight = true
        await processExpiredTimers()
        operationInFlight = false
        if Date().timeIntervalSince(lastRefresh) >= 3 { await refresh() }
    }

    func shutdown() async {
        await stopRecording()
        guard !operationInFlight else { return }
        operationInFlight = true
        var errors: [String] = []
        for change in journal.changes.reversed() where change.owner == .standalone && transient.contains(change.switchID) {
            do {
                try await restoreChange(change)
                journal.timers.removeValue(forKey: change.switchID.rawValue)
                try persist()
            } catch { errors.append("\(change.switchID.title): \(error.localizedDescription)") }
        }
        for adapter in adapters.values { adapter.shutdown() }
        operationInFlight = false
        if !errors.isEmpty {
            phase = .recoveryNeeded
            issue = "Some changes could not be restored before quitting:\n" + errors.joined(separator: "\n")
        }
    }

    private func performStandalone(_ id: SwitchID, enabled: Bool, foregroundPID: Int32?, manual: Bool) async throws {
        guard let adapter = adapters[id] else { throw SwitchError.unavailable("This switch is unavailable.") }
        if enabled, let reason = await adapter.capability().reason { throw SwitchError.unavailable(reason) }
        if manual {
            for recordingChange in journal.changes.reversed() where recordingChange.switchID == id && recordingChange.owner == .recording {
                // Release the recording lease as well as relinquishing its journal entry.
                try await restoreChange(recordingChange)
            }
            journal.timers.removeValue(forKey: id.rawValue)
            try persist()
        }
        let priorStandalone = journal.changes.last { $0.switchID == id && $0.owner == .standalone && $0.phase == .committed }
        let original = try await adapter.snapshot()
        let operation = JournalChange(switchID: id, owner: .standalone, original: original, requestedEnabled: enabled, foregroundPID: foregroundPID)
        journal.changes.append(operation)
        try persist()
        do {
            if !enabled, restoresStandaloneSnapshot.contains(id), let priorStandalone {
                try await adapter.restore(priorStandalone.original, context: operation.context)
            } else { try await adapter.apply(enabled: enabled, context: operation.context) }
            let actual = try await adapter.snapshot()
            try updateChange(operation.id, applied: actual, phase: .applied)
            journal.changes.removeAll { $0.switchID == id && $0.owner == .standalone }
            if enabled && !id.isMomentary {
                let deadline = defaultDeadline(for: id)
                if let deadline { journal.timers[id.rawValue] = deadline }
                if transient.contains(id) || restoresStandaloneSnapshot.contains(id) || deadline != nil {
                    var committed = operation
                    committed.original = priorStandalone?.original ?? original
                    committed.applied = actual
                    committed.phase = .committed
                    journal.changes.append(committed)
                }
            } else { journal.timers.removeValue(forKey: id.rawValue) }
            try persist()
        } catch {
            // The prepared record remains durable if the OS changed before reporting failure.
            let failure = error
            if !journal.changes.contains(where: { $0.id == operation.id }), let saved = try? store.load() {
                journal = saved
                syncPublishedJournal()
            }
            if let pending = journal.changes.first(where: { $0.id == operation.id }) {
                do { try await restoreChange(pending) }
                catch { phase = .recoveryNeeded; throw SwitchError.failed("\(failure.localizedDescription) Recovery also failed: \(error.localizedDescription)") }
            }
            throw failure
        }
    }

    private func defaultDeadline(for id: SwitchID) -> Date? {
        guard id.supportsTimer else { return nil }
        if id == .keepAwake {
            switch settings.preferences.awakeTimerMode {
            case .indefinite: return nil
            case .clock: return settings.preferences.awakeUntil
            case .duration: return Date().addingTimeInterval(Double(max(1, settings.preferences.keepAwakeMinutes)) * 60)
            }
        }
        guard let minutes = settings.preferences.autoOffMinutes[id.rawValue], minutes > 0 else { return nil }
        return Date().addingTimeInterval(Double(minutes) * 60)
    }

    private func restoreRecordingChanges() async -> [String] {
        var errors: [String] = []
        for change in journal.changes.reversed() where change.owner == .recording {
            do { try await restoreChange(change) }
            catch { errors.append("\(change.switchID.title): \(error.localizedDescription)") }
        }
        if !journal.changes.contains(where: { $0.owner == .recording }) {
            journal.session = nil
            do { try persist() } catch { errors.append("Recovery journal: \(error.localizedDescription)") }
        }
        return errors
    }

    private func restoreChange(_ change: JournalChange) async throws {
        guard let adapter = adapters[change.switchID] else { throw SwitchError.unavailable("The recovery adapter is unavailable.") }
        let originalMatches = try await adapter.matches(change.original)
        if !originalMatches {
            let ownsCurrent: Bool
            if let applied = change.applied { ownsCurrent = try await adapter.matches(applied) }
            else { ownsCurrent = (await adapter.status()).isEnabled == change.requestedEnabled }
            if ownsCurrent {
                if let index = journal.changes.firstIndex(where: { $0.id == change.id }) { journal.changes[index].phase = .restoring }
                try persist()
                try await adapter.restore(change.original, context: change.context)
                guard try await adapter.matches(change.original) else { throw SwitchError.failed("The previous state could not be verified.") }
            }
            // A different current value belongs to the user or OS and is left alone.
        } else if transient.contains(change.switchID) {
            // Effective state can match while this owner still holds a separate lease.
            try await adapter.restore(change.original, context: change.context)
        }
        journal.changes.removeAll { $0.id == change.id }
        try persist()
    }

    private func processExpiredTimers() async {
        for (id, deadline) in timers where deadline <= Date() {
            let recordingOwns = journal.changes.contains { $0.switchID == id && $0.owner == .recording }
            if recordingOwns && id != .keepAwake { continue }
            do {
                if let record = journal.changes.last(where: { $0.switchID == id && $0.owner == .standalone }), let applied = record.applied,
                   let adapter = adapters[id], try await !adapter.matches(applied) {
                    journal.changes.removeAll { $0.id == record.id }
                    journal.timers.removeValue(forKey: id.rawValue)
                    try persist()
                    continue
                }
                try await performStandalone(id, enabled: false, foregroundPID: nil, manual: false)
            } catch { issue = "\(id.title) could not turn off: \(error.localizedDescription)" }
        }
    }

    private func orderedRecordingSwitches() -> [SwitchID] {
        let requested = settings.preferences.recordingSwitches.filter(\.supportsRecording)
        var result = settings.preferences.switchOrder.filter { requested.contains($0) }
        result.append(contentsOf: SwitchID.allCases.filter { requested.contains($0) && !result.contains($0) })
        return result
    }

    private func updateStatuses() async {
        var result: [SwitchID: SwitchStatus] = [:]
        for id in SwitchID.allCases {
            guard let adapter = adapters[id] else { result[id] = SwitchStatus(state: .unsupported, detail: "This switch is unavailable."); continue }
            result[id] = await adapter.status()
        }
        statuses = result
        now = Date()
    }

    private func updateChange(_ id: UUID, applied: ResourceSnapshot, phase: JournalChangePhase) throws {
        guard let index = journal.changes.firstIndex(where: { $0.id == id }) else { throw SwitchError.failed("The recovery operation is missing.") }
        journal.changes[index].applied = applied
        journal.changes[index].phase = phase
        try persist()
    }

    private func persist() throws {
        try store.save(journal)
        syncPublishedJournal()
    }

    private func syncPublishedJournal() {
        timers = Dictionary(uniqueKeysWithValues: journal.timers.compactMap { key, value in SwitchID(rawValue: key).map { ($0, value) } })
        startedAt = journal.session?.startedAt
        endsAt = journal.session?.endsAt
    }
}
