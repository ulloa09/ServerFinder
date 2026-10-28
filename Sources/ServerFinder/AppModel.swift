import Foundation
import Observation
import ServerFinderCore

struct ScanProgress: Equatable {
    var folderID: UUID
    var folderName: String
    var found: Int
}

/// One search result, ready to show and open.
struct SearchHit: Identifiable, Hashable {
    let result: SearchResult
    let folder: IndexedFolder

    var id: String { result.share + "/" + result.relativePath }
    var name: String { result.name }
    var isDirectory: Bool { result.isDirectory }
    var url: URL { folder.url.appendingPathComponent(result.relativePath, isDirectory: result.isDirectory) }

    /// Where the item lives, e.g. "Stats › 2024 › Reports".
    var location: String {
        let parents = result.relativePath.split(separator: "/").dropLast().map(String.init)
        return ([folder.name] + parents).joined(separator: " › ")
    }
}

/// App state: the folders to index, the scan queue and searching.
@MainActor @Observable
final class AppModel {
    private(set) var folders: [IndexedFolder] {
        didSet { IndexedFolderStorage.save(folders) }
    }
    private(set) var itemCounts: [UUID: Int] = [:]
    private(set) var scanErrors: [UUID: String] = [:]
    private(set) var currentScan: ScanProgress?
    private(set) var queuedScans: [UUID] = []
    /// Increases whenever newly indexed items become searchable, so open searches can refresh.
    private(set) var indexVersion = 0

    let store: IndexStore?
    let storeError: String?

    private let scanner = ShareScanner()
    private var scanTask: Task<Void, Never>?

    init() {
        folders = IndexedFolderStorage.load()
        do {
            store = try IndexStore(url: Self.indexURL)
            storeError = nil
        } catch {
            store = nil
            storeError = String(describing: error)
        }
        refreshCounts()
    }

    static var indexURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("ServerFinder", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    var totalItems: Int { itemCounts.values.reduce(0, +) }

    func isQueued(_ folder: IndexedFolder) -> Bool { queuedScans.contains(folder.id) }

    // MARK: Folders

    enum AddFolderResult {
        case added
        case alreadyIncluded(in: IndexedFolder)
    }

    @discardableResult
    func addFolder(at url: URL) -> AddFolderResult {
        let path = url.standardizedFileURL.path
        if let existing = folders.first(where: { $0.contains(path: path) }) {
            return .alreadyIncluded(in: existing)
        }
        // A new parent folder replaces subfolders that were added on their own.
        let newFolder = IndexedFolder(id: UUID(), path: path, lastIndexedAt: nil)
        for subfolder in folders where newFolder.contains(path: subfolder.path) {
            removeFolder(subfolder)
        }
        folders.append(newFolder)
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        enqueueScan(of: newFolder.id)
        return .added
    }

    func removeFolder(_ folder: IndexedFolder) {
        folders.removeAll { $0.id == folder.id }
        queuedScans.removeAll { $0 == folder.id }
        itemCounts[folder.id] = nil
        scanErrors[folder.id] = nil
        if currentScan?.folderID == folder.id { scanTask?.cancel() }
        guard let store else { return }
        Task.detached(priority: .utility) {
            try? store.removeShare(folder.shareKey)
        }
        indexVersion += 1
    }

    // MARK: Scanning

    func rescanAll() {
        for folder in folders { enqueueScan(of: folder.id) }
    }

    private func enqueueScan(of folderID: UUID) {
        guard currentScan?.folderID != folderID, !queuedScans.contains(folderID) else { return }
        queuedScans.append(folderID)
        startNextScanIfIdle()
    }

    private func startNextScanIfIdle() {
        guard scanTask == nil, let store else { return }
        while !queuedScans.isEmpty {
            let folderID = queuedScans.removeFirst()
            guard let folder = folders.first(where: { $0.id == folderID }) else { continue }
            currentScan = ScanProgress(folderID: folder.id, folderName: folder.name, found: 0)
            scanErrors[folder.id] = nil
            let scanner = scanner
            scanTask = Task.detached(priority: .utility) { [weak self] in
                let result: Result<Int, any Error>
                do {
                    let replacement = try store.beginReplacing(share: folder.shareKey)
                    for try await batch in scanner.scan(root: folder.url) {
                        let becameSearchable = try replacement.insert(batch)
                        let found = replacement.insertedCount
                        await self?.scanMadeProgress(found: found, becameSearchable: becameSearchable)
                    }
                    try Task.checkCancellation()
                    try replacement.commit()
                    result = .success(replacement.insertedCount)
                } catch {
                    result = .failure(error)
                }
                await self?.scanFinished(folder, result: result)
            }
            return
        }
    }

    private func scanMadeProgress(found: Int, becameSearchable: Bool) {
        currentScan?.found = found
        if becameSearchable { indexVersion += 1 }
    }

    private func scanFinished(_ folder: IndexedFolder, result: Result<Int, any Error>) {
        scanTask = nil
        currentScan = nil
        switch result {
        case .success(let count):
            itemCounts[folder.id] = count
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index].lastIndexedAt = .now
            }
        case .failure(is CancellationError):
            break
        case .failure(ScanError.rootUnavailable):
            scanErrors[folder.id] = String(localized: "Not connected. Connect to the server in Finder, then rescan.")
        case .failure(let error):
            scanErrors[folder.id] = String(localized: "Couldn't finish indexing: \(error.localizedDescription)")
        }
        indexVersion += 1
        startNextScanIfIdle()
    }

    private func refreshCounts() {
        guard let store else { return }
        let folders = folders
        Task.detached(priority: .utility) { [weak self] in
            var counts: [UUID: Int] = [:]
            for folder in folders {
                counts[folder.id] = try? store.count(share: folder.shareKey)
            }
            await self?.mergeCounts(counts)
        }
    }

    private func mergeCounts(_ counts: [UUID: Int]) {
        itemCounts.merge(counts) { current, _ in current }
    }

    // MARK: Searching

    func search(_ text: String) async -> [SearchHit] {
        guard let store else { return [] }
        let results = await Task.detached(priority: .userInitiated) {
            (try? store.search(text)) ?? []
        }.value
        let foldersByKey = Dictionary(uniqueKeysWithValues: folders.map { ($0.shareKey, $0) })
        return results.compactMap { result in
            foldersByKey[result.share].map { SearchHit(result: result, folder: $0) }
        }
    }

    // MARK: Status

    /// A one-line summary for the search panel and the menu.
    var statusText: String {
        if let storeError {
            return String(localized: "The search index couldn't be opened: \(storeError)")
        }
        if let scan = currentScan {
            let found = scan.found.formatted()
            if queuedScans.isEmpty {
                return String(localized: "Indexing “\(scan.folderName)”… \(found) items found")
            }
            return String(localized: "Indexing “\(scan.folderName)”… \(found) items found · \(queuedScans.count) in queue")
        }
        if folders.isEmpty {
            return String(localized: "No folders selected yet")
        }
        return String(localized: "\(totalItems.formatted()) items indexed")
    }
}
