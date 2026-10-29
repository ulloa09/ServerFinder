import AppKit
import Quartz
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

    // MARK: Quick Look

    /// The file Quick Look should show (the selected result).
    var previewURL: () -> URL? = { nil }
    /// Moves the selection while the preview is open (↑/↓), so the preview follows.
    var moveSelection: (Int) -> Void = { _ in }

    var isPreviewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func togglePreview() {
        guard let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible {
            preview.orderOut(nil)
        } else {
            preview.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // Quick Look calls these on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            // Give the keyboard back to the search panel when the preview closes.
            if isVisible { makeKey() }
        }
    }
}

extension SearchPanel: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL() == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL() as NSURL?
    }

    /// ↑/↓ inside the preview move through the results, like in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125: moveSelection(1)
        case 126: moveSelection(-1)
        default: return false
        }
        panel.reloadData()
        return true
    }
}

/// SwiftUI content that never acts as a window-drag handle, so dragging a result
/// drags the file instead of moving the panel.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
