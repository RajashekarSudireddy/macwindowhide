import Foundation

/// Shared outcome checks for App Intents. A refused request throws instead of reporting success,
/// and only an issue produced by the accepted request is reported.
@MainActor enum AutomationRequest {
    static func startRecording(_ coordinator: MutationCoordinator, foregroundPID: Int32?, waitLimit: Duration = .seconds(5)) async throws {
        await waitForRunningOperation(coordinator, limit: waitLimit)
        guard await coordinator.startRecording(foregroundPID: foregroundPID) else { throw coordinator.refusalError }
        if !coordinator.isRecording { throw SwitchError.failed(coordinator.issue ?? "Recording Mode did not start.") }
    }

    static func stopRecording(_ coordinator: MutationCoordinator, waitLimit: Duration = .seconds(5)) async throws {
        await waitForRunningOperation(coordinator, limit: waitLimit)
        guard await coordinator.stopRecording() else { throw coordinator.refusalError }
        if coordinator.phase == .recoveryNeeded { throw SwitchError.failed(coordinator.issue ?? "Some changes still need restoration.") }
    }

    /// `enabled == nil` toggles the switch from its last read status.
    static func setSwitch(_ coordinator: MutationCoordinator, _ id: SwitchID, enabled: Bool?, foregroundPID: Int32?, waitLimit: Duration = .seconds(5)) async throws {
        await waitForRunningOperation(coordinator, limit: waitLimit)
        let target = enabled ?? !(coordinator.statuses[id]?.isEnabled ?? false)
        // setSwitch clears `issue` when it accepts the request, so a remaining issue belongs to this request.
        guard await coordinator.setSwitch(id, enabled: target, foregroundPID: foregroundPID) else { throw coordinator.refusalError }
        if let issue = coordinator.issue { throw SwitchError.failed(issue) }
    }

    /// Lets a short refresh or startup recovery finish instead of refusing immediately. A countdown is not
    /// waited for, so a restore request can still cancel it.
    private static func waitForRunningOperation(_ coordinator: MutationCoordinator, limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while coordinator.isBusy && coordinator.phase != .countdown && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
