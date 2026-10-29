import AppKit
import Observation
import ServiceManagement

/// The search shortcut and opening at login.
@MainActor @Observable
final class GeneralSettings {
    /// `nil` when the user turned the shortcut off.
    private(set) var searchShortcut: KeyShortcut?
    /// Set when the shortcut couldn't be activated, e.g. another app already uses it.
    private(set) var shortcutProblem: String?
    private(set) var launchAtLogin: LaunchAtLoginState = .off

    enum LaunchAtLoginState: Equatable {
        case off, on, needsApproval
        case unavailable(String)
    }

    @ObservationIgnored private var hotKey: GlobalHotKey?
    private static let shortcutKey = "searchShortcut"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.shortcutKey) {
            searchShortcut = try? JSONDecoder().decode(KeyShortcut?.self, from: data)
        } else {
            searchShortcut = .defaultSearch
        }
        refreshLaunchAtLogin()
    }

    /// Starts listening for the shortcut; `action` runs each time it's pressed.
    func activateShortcut(action: @escaping () -> Void) {
        hotKey = GlobalHotKey(onPress: action)
        applyShortcut()
    }

    func setSearchShortcut(_ shortcut: KeyShortcut?) {
        searchShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.shortcutKey)
        }
        applyShortcut()
    }

    /// While recording a new shortcut, the current one must not fire.
    func pauseShortcut() {
        hotKey?.register(nil)
    }

    func resumeShortcut() {
        applyShortcut()
    }

    private func applyShortcut() {
        guard let hotKey else { return }
        if hotKey.register(searchShortcut) {
            shortcutProblem = nil
        } else {
            shortcutProblem = String(localized: "Another app is already using this shortcut. Choose a different one.")
        }
    }

    // MARK: Open at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            launchAtLogin = .unavailable(String(localized: "Couldn't change this setting: \(error.localizedDescription)"))
        }
    }

    func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled: launchAtLogin = .on
        case .requiresApproval: launchAtLogin = .needsApproval
        case .notRegistered, .notFound: launchAtLogin = .off
        @unknown default: launchAtLogin = .off
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
