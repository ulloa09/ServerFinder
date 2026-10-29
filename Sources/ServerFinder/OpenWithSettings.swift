import AppKit
import Observation
import ServerFinderCore
import UniformTypeIdentifiers

/// The user's "open .pdf files with…" choices, and opening files with them.
@MainActor @Observable
final class OpenWithSettings {
    private(set) var rules: OpenWithRules {
        didSet { save() }
    }

    private static let key = "openWithRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(OpenWithRules.self, from: data) {
            rules = saved
        } else {
            rules = OpenWithRules()
        }
    }

    // MARK: Opening

    /// Opens a file with the app chosen for its type, or with the Mac's default app.
    func open(_ url: URL, isDirectory: Bool) {
        guard let bundleID = rules.appBundleID(forFileNamed: url.lastPathComponent, isDirectory: isDirectory),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Editing rules

    enum AddResult {
        case added(String)
        /// Nothing on this Mac opens the type by default: the user must pick an app.
        case needsApp(String)
        case invalid
    }

    /// Adds a rule for `typedExtension`, starting with the app that opens it today.
    func addRule(for typedExtension: String) -> AddResult {
        guard let fileExtension = OpenWithRules.normalizedExtension(typedExtension) else { return .invalid }
        if rules.appsByExtension[fileExtension] != nil { return .added(fileExtension) }
        guard let defaultApp = Self.defaultApp(forExtension: fileExtension),
              let bundleID = Bundle(url: defaultApp)?.bundleIdentifier
        else { return .needsApp(fileExtension) }
        rules.set(bundleID, forExtension: fileExtension)
        return .added(fileExtension)
    }

    func setApp(_ appURL: URL, forExtension fileExtension: String) {
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return }
        rules.set(bundleID, forExtension: fileExtension)
    }

    func removeRule(for fileExtension: String) {
        rules.remove(extension: fileExtension)
    }

    // MARK: Apps

    /// Where the rule's app is installed, or `nil` if it's no longer on this Mac.
    func appURL(forExtension fileExtension: String) -> URL? {
        rules.appsByExtension[fileExtension].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Apps that say they can open this type, default first, without duplicates.
    static func apps(forExtension fileExtension: String) -> [URL] {
        guard let type = UTType(filenameExtension: fileExtension) else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: type).filter { app in
            let id = Bundle(url: app)?.bundleIdentifier ?? app.path
            return seen.insert(id).inserted
        }
    }

    static func defaultApp(forExtension fileExtension: String) -> URL? {
        UTType(filenameExtension: fileExtension).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// Name and icon of an app, for showing it in lists and menus.
enum AppDisplay {
    static func name(of appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(of appURL: URL, size: CGFloat = 16) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
