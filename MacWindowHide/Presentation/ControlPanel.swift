import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: MutationCoordinator
    @State private var showAll = false
    private var shown: [SwitchID] {
        settings.preferences.switchOrder.filter {
            !settings.preferences.hiddenSwitches.contains($0) && (showAll || settings.preferences.visibleSwitches.contains($0))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 14, weight: .medium))
                Text("MacWindowHide").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await coordinator.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh switch states")
            }.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 14)
            recordingCard.padding(.horizontal, 12)
            if let issue = coordinator.issue {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(issue).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.5)).padding(.horizontal, 12).padding(.top, 8)
                Button("Review setup") { model.showSettings(.permissions) }.buttonStyle(.link).padding(.top, 5)
            }
            ScrollView {
                VStack(spacing: 1) {
                    HStack {
                        Text("Switches").fontWeight(.medium)
                        Spacer()
                        Text("\(coordinator.statuses.values.filter(\.isEnabled).count) on")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 7)
                    ForEach(shown) { id in switchRow(id) }
                }.padding(.horizontal, 10)
            }.frame(maxHeight: showAll ? 425 : 340)
            Button { showAll.toggle() } label: {
                HStack {
                    Text(showAll ? "Show less" : "Show all \(SwitchID.allCases.count)")
                    Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }.font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
            Divider()
            HStack {
                Button { model.showSettings() } label: { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Button("Quit") { model.quit() }
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 13)
        }.frame(width: 360).background(.regularMaterial)
            .alert("MacWindowHide", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: { Text(model.message ?? "") }
    }
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: coordinator.isRecording ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(coordinator.isRecording ? Color.red : Color.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording Mode").font(.system(size: 14, weight: .semibold))
                    Text(recordingSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if coordinator.isRecording { Text(model.elapsed).font(.system(size: 14, weight: .medium)).monospacedDigit() }
            }
            HStack {
                Button { Task { await model.toggleRecording() } } label: {
                    HStack {
                        if coordinator.isBusy && coordinator.phase != .countdown { ProgressView().controlSize(.mini) }
                        Text(recordingButton).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: coordinator.isRecording ? "arrow.uturn.backward" : "play.fill").font(.system(size: 10))
                    }.padding(.horizontal, 11).padding(.vertical, 8).background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }.buttonStyle(.plain).disabled(coordinator.isBusy && coordinator.phase != .countdown)
                if coordinator.isRecording {
                    Button("+15m") { coordinator.extendRecording(minutes: 15) }.controlSize(.small)
                } else {
                    Button { model.showSettings(.recording) } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.plain).padding(6).help("Choose Recording Mode actions")
                }
            }
            if let end = coordinator.endsAt {
                Text("Restores at \(end.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    private var recordingButton: String {
        switch coordinator.phase {
        case .idle: "Start Recording Mode"
        case .countdown: "Cancel countdown · \(coordinator.countdownRemaining)"
        case .preparing: "Preparing…"
        case .active: "Restore everything"
        case .restoring: "Restoring…"
        case .recoveryNeeded: "Retry restoration"
        }
    }
    private var recordingSubtitle: String {
        switch coordinator.phase {
        case .active: "Your screen is prepared."
        case .recoveryNeeded: "Some changes still need restoration."
        case .countdown: "Starting in \(coordinator.countdownRemaining)…"
        default: "\(settings.preferences.recordingSwitches.count) actions, one click."
        }
    }
    private func switchRow(_ id: SwitchID) -> some View {
        let status = coordinator.statuses[id] ?? .unknown
        return HStack(spacing: 11) {
            Image(systemName: id.symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(id.title).font(.system(size: 12, weight: .medium))
                if let timer = model.timerLabel(id) { Text(timer).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit() }
                else if !status.detail.isEmpty && (status.state != .off || id == .airPods) {
                    Text(status.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if id.isMomentary {
                Button("Start") { Task { await model.toggle(id) } }.controlSize(.mini)
            } else if status.state == .needsPermission {
                Button("Set up") { model.showSettings(.permissions) }.controlSize(.mini)
            } else if status.state == .unsupported {
                Image(systemName: "minus.circle").foregroundStyle(.tertiary).help(status.detail)
            } else {
                Toggle(id.title, isOn: Binding(get: { status.isEnabled }, set: { _ in Task { await model.toggle(id) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.primary)
                    .accessibilityLabel(id.title).disabled(coordinator.isBusy)
            }
            Menu {
                Button("Settings…") { model.showSettings(id == .backdrop ? .backdrop : id == .menuBar ? .menuBar : .switches) }
                if id.supportsTimer {
                    ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
                        Button("Turn off in \(minutes) minutes") {
                            Task { await coordinator.scheduleAutoOff(id, date: Date().addingTimeInterval(Double(minutes) * 60)) }
                        }.disabled(!status.isEnabled)
                    }
                    if coordinator.timers[id] != nil { Button("Cancel timer") { coordinator.cancelAutoOff(id) } }
                }
                if id == .keepAwake {
                    Divider()
                    ForEach([15, 60, 240], id: \.self) { minutes in Button("Add \(minutes) minutes") { Task { await model.extendAwake(minutes: minutes) } } }
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 13, height: 23) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("\(id.title) options")
        }.padding(.horizontal, 9).padding(.vertical, 8).contentShape(Rectangle())
    }
}
