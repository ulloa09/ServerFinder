import AppKit
import Observation

/// State of the search panel: the typed text, results and the selected row.
@MainActor @Observable
final class SearchController {
    let model: AppModel

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var results: [SearchHit] = []
    var selectedIndex = 0
    /// True once results for the current text have arrived.
    private(set) var hasResults = false
    /// A short message shown above the results, e.g. when a file couldn't be opened.
    var notice: String?
    /// Increases each time the panel is shown, so the view can focus the text field.
    private(set) var focusRequest = 0

    private var searchTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var selectedHit: SearchHit? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

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
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), results.count - 1)
    }

    /// Opens the selected item. Returns `true` when it opened and the panel can close.
    func openSelected() -> Bool {
        guard let hit = selectedHit else { return false }
        return open(hit)
    }

    func open(_ hit: SearchHit) -> Bool {
        guard FileManager.default.fileExists(atPath: hit.url.path) else {
            if FileManager.default.fileExists(atPath: hit.folder.path) {
                notice = String(localized: "“\(hit.name)” is no longer on the server. Rescan to update the results.")
            } else {
                notice = String(localized: "“\(hit.folder.name)” isn't connected. Connect to the server in Finder, then try again.")
            }
            return false
        }
        NSWorkspace.shared.open(hit.url)
        return true
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        notice = nil
        let text = trimmedQuery
        guard !text.isEmpty else {
            results = []
            selectedIndex = 0
            hasResults = false
            return
        }
        let previousSelection = selectedHit?.id
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let hits = await model.search(text)
            guard !Task.isCancelled else { return }
            results = hits
            // Keep the same row selected when results refresh underneath the user.
            selectedIndex = debounce ? 0 : (hits.firstIndex { $0.id == previousSelection } ?? 0)
            hasResults = true
        }
    }
}
