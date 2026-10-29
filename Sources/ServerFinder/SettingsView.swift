import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let general: GeneralSettings

    var body: some View {
        TabView {
            FoldersSettingsView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .tabItem { Label("Folders", systemImage: "folder") }
            ExclusionsSettingsView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .tabItem { Label("Excluded", systemImage: "eye.slash") }
            GeneralSettingsView(model: model, settings: general)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        // Every tab gets the same space, so switching tabs never resizes the window.
        .frame(minWidth: 600, minHeight: 560)
    }
}

private struct GeneralSettingsView: View {
    let model: AppModel
    let settings: GeneralSettings

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                LabeledContent("Search shortcut") {
                    ShortcutRecorder(settings: settings)
                }
                if let problem = settings.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Press it in any app to open the search. Click the shortcut to change it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Rescan automatically", selection: $model.rescanIntervalHours) {
                    Text("Every hour").tag(1)
                    Text("Every 2 hours").tag(2)
                    Text("Every 4 hours").tag(4)
                    Text("Every 8 hours").tag(8)
                    Text("Once a day").tag(24)
                    Text("Only when a folder connects").tag(0)
                }
            } footer: {
                Text("Folders are also scanned when their server connects and when ServerFinder starts. Searching always works with the last list, even while scanning.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open ServerFinder when you log in", isOn: Binding(
                    get: { settings.launchAtLogin == .on || settings.launchAtLogin == .needsApproval },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                switch settings.launchAtLogin {
                case .needsApproval:
                    HStack {
                        Text("macOS needs your approval in Login Items.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items Settings") { settings.openLoginItemsSettings() }
                    }
                case .unavailable(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .on, .off:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

/// Click, then press the new key combination. Esc cancels, Delete turns the shortcut off.
private struct ShortcutRecorder: View {
    let settings: GeneralSettings
    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(label)
                    .frame(minWidth: 150)
            }
            if settings.searchShortcut != nil && !isRecording {
                Button {
                    settings.setSearchShortcut(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Turn off the shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return String(localized: "Press the new shortcut…") }
        return settings.searchShortcut?.displayString ?? String(localized: "None — click to set")
    }

    private func startRecording() {
        settings.pauseShortcut()
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let shortcut = KeyShortcut(event: event)
            MainActor.assumeIsolated {
                switch keyCode {
                case 53: // Esc
                    stopRecording()
                case 51, 117: // Delete, Forward Delete
                    settings.setSearchShortcut(nil)
                    stopRecording()
                default:
                    if let shortcut {
                        settings.setSearchShortcut(shortcut)
                        stopRecording()
                    } else {
                        NSSound.beep() // Needs ⌘, ⌥ or ⌃
                    }
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isRecording = false
        settings.resumeShortcut()
    }
}
