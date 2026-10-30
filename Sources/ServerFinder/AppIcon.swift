import AppKit

/// Shows the dark icon inside the app (About panel, alerts) while the Mac is in dark mode.
/// Finder and Spotlight always show the bundle icon: switching it there needs an icon built
/// with Xcode's Icon Composer.
@MainActor
enum AppIcon {
    private static var observation: NSKeyValueObservation?

    static func followAppearance() {
        update()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in update() }
        }
    }

    private static func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = isDark ? "AppIconDark" : "AppIcon"
        NSApp.applicationIconImage = Bundle.main.image(forResource: name)
    }
}
