import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = AppModel()
    private let openWith = OpenWithSettings()
    private lazy var searchController = SearchController(model: model, openWith: openWith)
    private let general = GeneralSettings()
    private lazy var shareMonitor = ShareMonitor(model: model)

    private var statusItem: NSStatusItem!
    private var panel: SearchPanel!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    /// The right-click menu while it's open, and what refreshes it.
    private var statusLineItem: NSMenuItem?
    private var folderStatusItems: [(folder: IndexedFolder, item: NSMenuItem)] = []
    private var menuRefreshTimer: Timer?
    /// Makes the menu bar icon pulse while indexing.
    private var scanningBlinkTimer: Timer?
    /// When the panel last closed. Clicking the menu bar icon closes the panel (it loses focus)
    /// just before the click arrives; this keeps that click from reopening it.
    private var panelClosedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)
        setUpStatusItem()
        panel = SearchPanel(rootView: SearchView(
            controller: searchController,
            general: general,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onDidOpen: { [weak self] in self?.hidePanel() }
        ))
        panel.delegate = self
        general.activateShortcut { [weak self] in self?.searchShortcutPressed() }

        shareMonitor.start()
        if model.folders.isEmpty {
            showSettings()
        } else {
            model.scanConnectedFolders()
        }
    }

    // MARK: Menu bar icon

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "ServerFinder")
        button.image?.isTemplate = true
        button.toolTip = String(localized: "ServerFinder — click to search, right-click for options")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observeScanning()
    }

    /// Keeps the menu bar icon in sync with whether a scan is running.
    private func observeScanning() {
        let isScanning = withObservationTracking {
            model.currentScan != nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeScanning() }
        }
        setScanningIndicator(isScanning)
    }

    private func setScanningIndicator(_ isScanning: Bool) {
        guard let button = statusItem.button else { return }
        button.toolTip = isScanning
            ? model.statusText
            : String(localized: "ServerFinder — click to search, right-click for options")
        guard isScanning != (scanningBlinkTimer != nil) else { return }
        if isScanning {
            let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let button = self?.statusItem.button else { return }
                    button.appearsDisabled.toggle()
                    button.toolTip = self?.model.statusText
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            scanningBlinkTimer = timer
        } else {
            scanningBlinkTimer?.invalidate()
            scanningBlinkTimer = nil
            button.appearsDisabled = false
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else if panel.isVisible {
            hidePanel()
        } else if Date().timeIntervalSince(panelClosedAt) > 0.3 {
            showPanel(belowStatusItem: true)
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Search Server Files"), action: #selector(searchFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLineItem = status
        folderStatusItems = model.folders.map { folder in
            let item = NSMenuItem(title: folder.name, action: #selector(openSettings), keyEquivalent: "")
            item.indentationLevel = 1
            menu.addItem(item)
            return (folder, item)
        }
        refreshStatusMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Rescan Now"), action: #selector(rescanNow), keyEquivalent: "")
            .isEnabled = !model.folders.isEmpty
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit ServerFinder"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        menu.autoenablesItems = false
        menu.delegate = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Updates the status lines; runs every half second while the menu is open.
    private func refreshStatusMenu() {
        statusLineItem?.title = model.statusText
        for (folder, item) in folderStatusItems {
            let current = model.folders.first { $0.id == folder.id } ?? folder
            item.attributedTitle = Self.twoLineTitle(current.name, detail: model.statusDetail(for: current))
            item.image = model.scanErrors[folder.id] == nil
                ? nil
                : NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        }
    }

    private static func twoLineTitle(_ title: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    func menuWillOpen(_ menu: NSMenu) {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusMenu() }
        }
        // .common so it also fires while the menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
        statusLineItem = nil
        folderStatusItems = []
    }

    @objc private func searchFromMenu() { showPanel(belowStatusItem: true) }
    @objc private func rescanNow() { model.rescanAll() }
    @objc func openSettings() { showSettings() }

    // MARK: Search panel

    private func searchShortcutPressed() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(belowStatusItem: false)
        }
    }

    private func showPanel(belowStatusItem: Bool) {
        let size = panel.frame.size
        if belowStatusItem, let buttonWindow = statusItem.button?.window,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let icon = buttonWindow.frame
            let visible = screen.visibleFrame
            let x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: icon.minY - size.height - 6))
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            // Like Spotlight: centered, in the upper part of the screen the user is working on.
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - visible.height * 0.18 - size.height
            ))
        }
        searchController.panelWillShow()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panelClosedAt = Date()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { hidePanel() }
    }

    /// Arrow keys, Return and Esc work while typing in the search field.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let shortcut: PanelShortcut.Modifier
            switch modifiers {
            case []: shortcut = .none
            case .command: shortcut = .command
            default: return event
            }
            let windowNumber = event.windowNumber
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated {
                guard let self, windowNumber == self.panel.windowNumber else { return false }
                return self.handlePanelKey(keyCode, modifier: shortcut)
            }
            return handled ? nil : event
        }
    }

    private func handlePanelKey(_ keyCode: UInt16, modifier: PanelShortcut.Modifier) -> Bool {
        switch (keyCode, modifier) {
        case (125, .none): // Down arrow
            searchController.moveSelection(by: 1)
        case (126, .none): // Up arrow
            searchController.moveSelection(by: -1)
        case (36, .none), (76, .none): // Return, Enter
            if searchController.openSelected() { hidePanel() }
        case (36, .command), (76, .command): // ⌘Return: show in Finder
            guard let hit = searchController.selectedHit else { return true }
            if searchController.revealInFinder(hit) { hidePanel() }
        case (8, .command): // ⌘C: copy the result's path, unless text is selected in the search field
            guard let hit = searchController.selectedHit, !searchFieldHasSelectedText else { return false }
            searchController.copyPath(hit)
        case (53, .none): // Esc: clear the text first, then close
            if searchController.query.isEmpty {
                hidePanel()
            } else {
                searchController.query = ""
            }
        default:
            return false
        }
        return true
    }

    private var searchFieldHasSelectedText: Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    // MARK: Settings

    private func showSettings() {
        hidePanel()
        if settingsWindow == nil {
            let content = NSHostingController(rootView: SettingsView(model: model, general: general, openWith: openWith))
            // The window keeps the size the user gives it; SwiftUI only sets the minimum.
            content.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: content)
            window.title = String(localized: "ServerFinder Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 660, height: 640))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

enum PanelShortcut {
    enum Modifier { case none, command }
}
