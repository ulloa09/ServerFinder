import AppKit
import Observation
import ServerFinderCore

/// State of the search panel: the typed text, results and the selected row.
@MainActor @Observable
final class SearchController {
    let model: AppModel

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// Items whose name or folders match.
    private(set) var results: [SearchHit] = []
    /// Documents whose text matches, shown in their own tab.
    private(set) var contentResults: [SearchHit] = []

    enum ResultsTab: Hashable { case names, contents }
    /// Which list is showing; `selectedIndex` points into it.
    var tab: ResultsTab = .names {
        didSet { if tab != oldValue { selectedIndex = 0 } }
    }
    var visibleResults: [SearchHit] { tab == .names ? results : contentResults }
    var selectedIndex = 0
    /// True once results for the current text have arrived.
    private(set) var hasResults = false
    /// A short message shown above the results, e.g. when a file couldn't be opened.
    var notice: String?
    /// A brief success message, e.g. after copying a path. Clears itself.
    private(set) var confirmation: String?
    private var confirmationTask: Task<Void, Never>?
    /// Increases each time the panel is shown, so the view can focus the text field.
    private(set) var focusRequest = 0

    private var searchTask: Task<Void, Never>?
    /// Called when an item opens after its share was connected first (the panel can close then).
    var onDidOpenLater: (() -> Void)?
    private var connectTask: Task<Void, Never>?

    private let openWith: OpenWithSettings

    init(model: AppModel, openWith: OpenWithSettings) {
        self.model = model
        self.openWith = openWith
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The words being searched for, as matched (lowercase, no accents). Used to highlight names.
    private(set) var searchTerms: [String] = []
    var selectedHit: SearchHit? {
        let visible = visibleResults
        return visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil
    }

    func panelWillShow() {
        focusRequest += 1
        notice = nil
        refresh()
    }

    /// Runs the current search again, e.g. after more items were indexed.
    func refresh() {
        guard !trimmedQuery.isEmpty else { return }
        scheduleSearch(debounce: false)
    }

    func moveSelection(by offset: Int) {
        let count = visibleResults.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), count - 1)
    }

    func switchTab() {
        guard model.contentSettings.isEnabled else { tab = .names; return }
        tab = tab == .names ? .contents : .names
    }

    /// Opens the selected item. Returns `true` when it opened and the panel can close.
    func openSelected() -> Bool {
        guard let hit = selectedHit else { return false }
        return open(hit)
    }

    func open(_ hit: SearchHit) -> Bool {
        perform(on: hit) { [openWith] url in openWith.open(url, isDirectory: hit.isDirectory) }
    }

    /// Shows the item selected in a Finder window. Returns `true` when the panel can close.
    func revealInFinder(_ hit: SearchHit) -> Bool {
        perform(on: hit) { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Runs `action` on the item now if it's reachable (returning `true`). If its share isn't
    /// connected, connects first and runs `action` afterwards (returning `false`).
    private func perform(on hit: SearchHit, _ action: @escaping (URL) -> Void) -> Bool {
        if !FileManager.default.fileExists(atPath: hit.folder.path), hit.folder.mountURL != nil {
            connectThenPerform(on: hit, action)
            return false
        }
        guard isReachable(hit) else { return false }
        action(hit.url)
        return true
    }

    private func connectThenPerform(on hit: SearchHit, _ action: @escaping (URL) -> Void) {
        guard connectTask == nil else { return }
        notice = String(localized: "Connecting to “\(hit.folder.name)”…")
        connectTask = Task {
            defer { connectTask = nil }
            do {
                let folder = try await model.connect(hit.folder)
                let url = folder.url.appendingPathComponent(hit.result.relativePath, isDirectory: hit.isDirectory)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    notice = String(localized: "“\(hit.name)” is no longer on the server. Rescan to update the results.")
                    return
                }
                notice = nil
                action(url)
                onDidOpenLater?()
            } catch let failure as ShareMounter.Failure where failure.isCancelled {
                notice = nil
            } catch {
                notice = String(localized: "Couldn't connect to “\(hit.folder.name)”. Check that this Mac is on the office network (or VPN), then try again.")
            }
        }
    }

    func copyPath(_ hit: SearchHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.url.path, forType: .string)
        showConfirmation(String(localized: "Path copied"))
    }

    /// Whether the item can be shown in Quick Look (explains why not when it can't).
    func canPreview(_ hit: SearchHit) -> Bool {
        isReachable(hit)
    }

    /// Checks the item is still there, and explains why not when it isn't.
    private func isReachable(_ hit: SearchHit) -> Bool {
        if FileManager.default.fileExists(atPath: hit.url.path) { return true }
        if FileManager.default.fileExists(atPath: hit.folder.path) {
            notice = String(localized: "“\(hit.name)” is no longer on the server. Rescan to update the results.")
        } else {
            notice = String(localized: "“\(hit.folder.name)” isn't connected. Connect to the server in Finder, then try again.")
        }
        return false
    }

    private func showConfirmation(_ message: String) {
        confirmation = message
        confirmationTask?.cancel()
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            confirmation = nil
        }
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        notice = nil
        let parsed = Query.parse(query)
        guard !parsed.isEmpty else {
            results = []
            contentResults = []
            searchTerms = []
            selectedIndex = 0
            hasResults = false
            return
        }
        let previousSelection = selectedHit?.id
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            async let nameHits = model.search(parsed)
            async let documentHits = model.searchContents(parsed)
            let hits = await nameHits
            let contentHits = await documentHits
            guard !Task.isCancelled else { return }
            results = hits
            contentResults = contentHits
            searchTerms = parsed.terms
            if debounce {
                // New text: start on names, unless only the contents matched.
                tab = hits.isEmpty && !contentHits.isEmpty ? .contents : .names
                selectedIndex = 0
            } else {
                // Results refreshed underneath the user: keep the same row selected.
                selectedIndex = visibleResults.firstIndex { $0.id == previousSelection } ?? 0
            }
            hasResults = true
        }
    }
}
