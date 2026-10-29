import AppKit
import SwiftUI

/// A floating, Spotlight-style window that takes keyboard input without
/// pulling the user out of the app they were working in.
final class SearchPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // Only the top edge moves the panel, so result rows can be dragged out as files.
        isMovableByWindowBackground = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = PanelHostingView(rootView: rootView)
        setContentSize(contentView?.fittingSize ?? NSSize(width: 640, height: 440))
    }

    override var canBecomeKey: Bool { true }
}

/// SwiftUI content that never acts as a window-drag handle, so dragging a result
/// drags the file instead of moving the panel.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
