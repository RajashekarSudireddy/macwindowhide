import AppKit
import ApplicationServices
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: MutationCoordinator
    @State private var menuRefresh = 0
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label("MacWindowHide", systemImage: "rectangle.on.rectangle.slash")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).padding(.top, 18)
                List(SettingsSection.allCases, selection: Binding<SettingsSection?>(get: { model.selectedSection }, set: { if let section = $0 { model.selectedSection = section } })) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }.listStyle(.sidebar)
                Text("Your screen, prepared.").font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Text(model.selectedSection.rawValue)
                        .font(.system(size: 24, weight: .semibold))
                        .listRowBackground(Color.clear)
                    switch model.selectedSection {
                    case .general: general
                    case .recording: recording
                    case .switches: switches
                    case .backdrop: backdrop
                    case .menuBar: menuBar
                    case .shortcuts: shortcuts
                    case .permissions: permissions
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden).id(model.selectedSection)
                    // AppKit-hosted split views on macOS 27 overlap the first row with the toolbar.
                    .padding(.top, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? 44 : 0)
                if let error = settings.persistenceError { Text(error).font(.caption).foregroundStyle(.red).padding(12) }
            }.frame(minWidth: 520)
        }.frame(minWidth: 760, minHeight: 600)
            .toolbar(.hidden, for: .windowToolbar)
            .alert("MacWindowHide", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: { Text(model.message ?? "") }
    }
    private var general: some View {
        Group {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text("MacWindowHide lives in your menu bar. Option-click its icon to start or restore Recording Mode.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Version", value: "1.0.0 · Personal edition")
                LabeledContent("Platform", value: "macOS 15 or later · Apple silicon and Intel")
            }
            Section("Keep Awake") {
                Picker("Stop keeping awake", selection: $settings.preferences.awakeTimerMode) {
                    Text("After a duration").tag(AwakeTimerMode.duration)
                    Text("At a time").tag(AwakeTimerMode.clock)
                    Text("When I turn it off").tag(AwakeTimerMode.indefinite)
                }
                if settings.preferences.awakeTimerMode == .duration {
                    Picker("Duration", selection: $settings.preferences.keepAwakeMinutes) {
                        ForEach([5, 15, 30, 60, 120, 240], id: \.self) { value in Text("\(value) minutes").tag(value) }
                    }
                } else if settings.preferences.awakeTimerMode == .clock {
                    DatePicker("Until", selection: $settings.preferences.awakeUntil, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Button("Midnight") {
                            settings.preferences.awakeUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86400)
                        }
                        Button("Tomorrow morning") {
                            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                            settings.preferences.awakeUntil = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                        }
                    }
                }
                Text("Keeps the display and idle system awake. Closing the lid or explicitly choosing Sleep still works.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Headphones") {
                TextField("Preferred paired Bluetooth address", text: $settings.preferences.preferredAirPodsAddress, prompt: Text("Select or enter an already-paired device"))
                Button("Choose paired headphones…") { model.chooseHeadphones() }
                Text("Pair headphones in System Settings first. Missing battery readings are shown as unavailable, never 0%.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local data") {
                Button("Open settings and recovery folder") { NSWorkspace.shared.open(settings.directory) }
                Text("No account, analytics or network service. The local recovery journal records only the state needed to undo this app’s changes.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var recording: some View {
        Group {
            Section {
                Toggle("Count down for three seconds", isOn: $settings.preferences.countdownEnabled)
                Picker("Automatically restore", selection: $settings.preferences.recordingLimitMinutes) {
                    Text("When I stop").tag(0)
                    ForEach([15, 30, 60, 120, 240], id: \.self) { value in Text("After \(value) minutes").tag(value) }
                }
                Text("Changes are recorded before they happen and restored in reverse. Detected manual changes are kept.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Actions") {
                ForEach(SwitchID.allCases.filter(\.supportsRecording)) { id in
                    Toggle(isOn: Binding(get: { settings.preferences.recordingSwitches.contains(id) }, set: { value in
                        if value { settings.preferences.recordingSwitches.insert(id) } else { settings.preferences.recordingSwitches.remove(id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(id.title, systemImage: id.symbol)
                            if let status = coordinator.statuses[id], !status.detail.isEmpty {
                                Text(status.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel(id.title)
                    .accessibilityHint(coordinator.statuses[id]?.detail ?? "")
                }
            }.disabled(coordinator.isRecording || coordinator.isBusy)
            Section("Keep these applications visible") {
                Text("The foreground application and Finder are always preserved. Add recorder or meeting app bundle identifiers, one per line.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { settings.preferences.excludedBundleIDs.joined(separator: "\n") }, set: {
                    settings.preferences.excludedBundleIDs = $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                })).font(.system(size: 12, design: .monospaced)).frame(height: 110)
            }
            if coordinator.phase == .recoveryNeeded {
                Section("Recovery") {
                    Text(coordinator.issue ?? "A previous session still has changes to restore.")
                    Button("Retry restoration") { Task { await coordinator.recover() } }
                }
            }
        }
    }
    private var switches: some View {
        Group {
            Section {
                Text("Drag rows to reorder or move them between groups. Each sustained switch can also have an automatic off timer.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(["Always shown", "Under Show all", "Hidden"], id: \.self) { group in
                Section(group) {
                    let ids = settings.preferences.switchOrder.filter { switchGroup($0) == group }
                    ForEach(ids) { id in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Label(id.title, systemImage: id.symbol).frame(maxWidth: .infinity, alignment: .leading)
                            if id.supportsTimer {
                                Picker("Auto-off", selection: Binding(get: { settings.preferences.autoOffMinutes[id.rawValue] ?? 0 }, set: { settings.preferences.autoOffMinutes[id.rawValue] = $0 })) {
                                    Text("No timer").tag(0)
                                    ForEach([5, 15, 30, 60, 120, 240], id: \.self) { value in Text("\(value)m").tag(value) }
                                }.labelsHidden().accessibilityLabel("\(id.title) auto-off").frame(width: 95)
                            }
                            Picker("Group", selection: Binding(get: { switchGroup(id) }, set: { moveSwitch(id, to: $0) })) {
                                ForEach(["Always shown", "Under Show all", "Hidden"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().accessibilityLabel("\(id.title) group").frame(width: 115)
                        }.draggable(id.rawValue).dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let dragged = SwitchID(rawValue: raw) else { return false }
                            moveSwitch(dragged, to: group, before: id)
                            return true
                        }
                    }
                    if ids.isEmpty { Text("Drop a switch here").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 30) }
                }.dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let id = SwitchID(rawValue: raw) else { return false }
                    moveSwitch(id, to: group)
                    return true
                }
            }
        }
    }
    private func switchGroup(_ id: SwitchID) -> String {
        if settings.preferences.hiddenSwitches.contains(id) { return "Hidden" }
        return settings.preferences.visibleSwitches.contains(id) ? "Always shown" : "Under Show all"
    }
    private func moveSwitch(_ id: SwitchID, to group: String, before target: SwitchID? = nil) {
        var prefs = settings.preferences
        prefs.hiddenSwitches.remove(id)
        prefs.visibleSwitches.remove(id)
        if group == "Hidden" { prefs.hiddenSwitches.insert(id) }
        if group == "Always shown" { prefs.visibleSwitches.insert(id) }
        if let target, target != id {
            prefs.switchOrder.removeAll { $0 == id }
            prefs.switchOrder.insert(id, at: prefs.switchOrder.firstIndex(of: target) ?? prefs.switchOrder.endIndex)
        }
        settings.preferences = prefs
    }
    private var backdrop: some View {
        Group {
            Section {
                Picker("Background", selection: $settings.preferences.backdropStyle) {
                    ForEach(BackdropStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                if [.color, .gradient, .mesh].contains(settings.preferences.backdropStyle) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                        ForEach(0..<14) { index in
                            Button { settings.preferences.backdropPreset = index; model.refreshBackdrop() } label: {
                                BackdropSwatch(style: settings.preferences.backdropStyle, index: index)
                                    .frame(height: 43).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.preferences.backdropPreset == index ? Color.primary : .clear, lineWidth: 2).padding(-3))
                            }.buttonStyle(.plain).help("Preset \(index + 1)")
                        }
                    }.padding(.vertical, 8)
                }
                if settings.preferences.backdropStyle == .custom { TextField("Color hex", text: $settings.preferences.customColorHex) }
                if settings.preferences.backdropStyle == .image {
                    Button("Choose image…") { model.importBackdrop() }
                    Text(settings.preferences.backdropImagePath.isEmpty ? "No picture selected" : URL(fileURLWithPath: settings.preferences.backdropImagePath).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Blur") {
                    Slider(value: $settings.preferences.backdropBlur, in: 0...50)
                        .accessibilityLabel("Backdrop blur")
                        .accessibilityValue("\(Int(settings.preferences.backdropBlur)) pixels")
                    Text("\(Int(settings.preferences.backdropBlur))").monospacedDigit().frame(width: 25)
                }
                LabeledContent("Dim") {
                    Slider(value: $settings.preferences.backdropDim, in: 0...0.8)
                        .accessibilityLabel("Backdrop dim")
                        .accessibilityValue("\(Int(settings.preferences.backdropDim * 100)) percent")
                    Text("\(Int(settings.preferences.backdropDim * 100))%").monospacedDigit().frame(width: 35)
                }
            }.onChange(of: settings.preferences) { _, _ in model.refreshBackdrop() }
            Section {
                Text("Backdrop follows the foreground window. Hide Desktop Icons uses a separate desktop cover, leaving your files and wallpaper settings intact.").font(.callout).foregroundStyle(.secondary)
                Button(coordinator.statuses[.backdrop]?.isEnabled == true ? "Hide preview" : "Preview backdrop") { Task { await model.toggle(.backdrop) } }
            }
        }
    }
    private var menuBar: some View {
        Group {
            Section {
                Picker("Hide Menu Bar controls", selection: $settings.preferences.menuBarMode) {
                    Text("Chosen menu bar icons").tag(MenuBarMode.icons)
                    Text("The whole menu bar").tag(MenuBarMode.wholeBar)
                }.disabled(coordinator.statuses[.menuBar]?.isEnabled == true || coordinator.isRecording)
                Toggle("Reveal hidden icons on hover", isOn: $settings.preferences.menuBarHoverReveal)
                Text("On macOS 27, all icons from the same application share one shelf. Some system privacy and status indicators cannot be hidden.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Icon shelves") {
                HStack {
                    Button("Refresh applications") { Task { await MenuBarController.shared.refreshInventory(); menuRefresh += 1 } }
                    Button("Reveal hidden") { model.revealMenuItems(all: false) }
                    Button("Reveal all") { model.revealMenuItems(all: true) }
                    Button("Collapse") { model.collapseMenuItems() }
                }
                if !AXIsProcessTrusted() {
                    Text("Grant Accessibility in Permissions to inventory menu bar applications.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(MenuBarController.shared.inventory) { owner in
                    Picker(owner.ownerName, selection: Binding(get: { settings.preferences.menuBarAssignments[owner.bundleID] ?? .visible }, set: { model.setMenuShelf($0, for: owner.bundleID); menuRefresh += 1 })) {
                        Text("Visible").tag(MenuShelf.visible)
                        Text("Hidden").tag(MenuShelf.hidden)
                        Text("Always hidden").tag(MenuShelf.alwaysHidden)
                    }
                }
                if MenuBarController.shared.inventory.isEmpty {
                    Text("Refresh to find applications with menu bar icons. On macOS 15/26, Command-drag icons between the separator items.").font(.caption).foregroundStyle(.secondary)
                }
            }.id(menuRefresh)
        }
    }
    private var shortcuts: some View {
        Group {
            Section {
                KeyboardShortcuts.Recorder("Recording Mode", name: .recordingMode)
                Text("The recorder warns about shortcut conflicts. Recording Mode and each switch also appear as actions in the Shortcuts app.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Individual switches") {
                ForEach(SwitchID.allCases) { id in KeyboardShortcuts.Recorder(id.title, name: .control(id)) }
            }
            Section("Siri and Shortcuts") {
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                Text("Try “Start Recording Mode in MacWindowHide”. Shortcuts can also set a control to on or off instead of toggling it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var permissions: some View {
        Group {
            Section {
                Text("Permissions are requested when you choose a feature. MacWindowHide does not record your screen or microphone.").font(.callout).foregroundStyle(.secondary)
                LabeledContent("Accessibility", value: AXIsProcessTrusted() ? "Granted" : "Not granted")
                HStack {
                    Button("Request Accessibility") { model.requestAccessibility() }
                    Button("Open Accessibility Settings") { model.openPrivacy("Privacy_Accessibility") }
                }
                Text("Used for menu bar organization and keyboard locking.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Automation") {
                Button(model.requestingAutomation ? "Requesting System Events control…" : "Allow System Events control") { Task { await model.requestAutomation() } }
                    .disabled(model.requestingAutomation)
                Button("Open Automation Settings") { model.openPrivacy("Privacy_Automation") }
                Text("Controls the Dock, whole menu bar and Dark Mode through the macOS scripting interface.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bluetooth") {
                Button("Choose paired headphones…") { model.chooseHeadphones() }
                Button("Open Bluetooth Privacy") { model.openPrivacy("Privacy_Bluetooth") }
            }
            Section("Control availability") {
                ForEach(SwitchID.allCases) { id in
                    let status = coordinator.statuses[id] ?? .unknown
                    LabeledContent(id.title) { VStack(alignment: .trailing, spacing: 3) {
                        Text(status.state.rawValue == "needsPermission" ? "Needs setup" : status.state.rawValue.capitalized)
                        if !status.detail.isEmpty { Text(status.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    }.frame(maxWidth: 330, alignment: .trailing) }
                }
                Button("Refresh all states") { Task { await coordinator.refresh() } }
            }
        }
    }
}

struct BackdropSwatch: View {
    let style: BackdropStyle
    let index: Int
    private var colors: [Color] {
        BackdropPalette.colors(for: index).map { Color(nsColor: $0) }
    }
    var body: some View {
        if style == .mesh {
            MeshGradient(width: 3, height: 3, points: [.init(0,0),.init(0.5,0),.init(1,0),.init(0,0.5),.init(0.4,0.6),.init(1,0.5),.init(0,1),.init(0.5,1),.init(1,1)], colors: [colors[0],colors[1],colors[0],colors[1],colors[2],colors[1],colors[2],colors[0],colors[2]])
        } else if style == .gradient { LinearGradient(colors: Array(colors.prefix(2)), startPoint: .topLeading, endPoint: .bottomTrailing) }
        else { colors[0] }
    }
}
