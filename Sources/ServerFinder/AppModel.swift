import Foundation
import Observation
import ServerFinderCore

struct ScanOutcome {
    var itemCount: Int
    var unreadableFolders: [String]
}

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
    /// What scans leave out. Changes apply from the next scan.
    private(set) var exclusions: ExclusionRules {
        didSet { ExclusionStorage.save(exclusions) }
    }
    /// Folders the last scan couldn't read (no permission), relative to each indexed folder.
    private(set) var unreadableFolders: [UUID: [String]] = [:]
    /// Increases whenever newly indexed items become searchable, so open searches can refresh.
    private(set) var indexVersion = 0

    let store: IndexStore?
    let storeError: String?

    private let scanner = ShareScanner()
    private var scanTask: Task<Void, Never>?

    init() {
        folders = IndexedFolderStorage.load()
        exclusions = ExclusionStorage.load()
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
        let location = ServerVolumes.location(of: path)
        let newFolder = IndexedFolder(
            id: UUID(), path: path, lastIndexedAt: nil,
            serverAddress: location?.address, pathInShare: location?.pathInShare
        )
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
        unreadableFolders[folder.id] = nil
        if currentScan?.folderID == folder.id { scanTask?.cancel() }
        guard let store else { return }
        Task.detached(priority: .utility) {
            try? store.removeShare(folder.shareKey)
        }
        indexVersion += 1
    }

    // MARK: Exclusions

    func setExclusionPatterns(_ patterns: [String]) {
        exclusions = ExclusionRules(patterns: patterns)
    }

    func restoreDefaultExclusions() {
        exclusions = .windowsServerDefaults
    }

    // MARK: Scanning

    /// Hours between automatic rescans while a folder stays connected; 0 turns them off
    /// (folders are then scanned only when they connect and when the app starts).
    var rescanIntervalHours: Int = UserDefaults.standard.object(forKey: "rescanIntervalHours") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(rescanIntervalHours, forKey: "rescanIntervalHours") }
    }

    func rescanAll() {
        updateFolderLocations()
        for folder in folders { enqueueScan(of: folder.id) }
    }

    /// Scans connected folders that were never indexed or whose last scan is older than the interval.
    func scanDueFolders() {
        updateFolderLocations()
        let interval = rescanIntervalHours > 0 ? TimeInterval(rescanIntervalHours) * 3_600 : nil
        for folder in folders where folder.isConnected
            && RescanSchedule.isDue(lastIndexedAt: folder.lastIndexedAt, interval: interval) {
            enqueueScan(of: folder.id)
        }
    }

    /// At launch: refresh every connected folder.
    func scanConnectedFolders() {
        updateFolderLocations()
        for folder in folders where folder.isConnected { enqueueScan(of: folder.id) }
    }

    /// A server share was just mounted: scan the folders that live on it.
    func volumeDidMount(at volume: URL) {
        guard let address = ServerVolumes.address(ofVolume: volume) else { return }
        updateFolderLocations()
        for folder in folders where folder.serverAddress == address && folder.isConnected {
            enqueueScan(of: folder.id)
        }
    }

    /// A share is going away: stop scanning it, keeping the list from its last complete scan.
    func volumeWillUnmount(at volume: URL) {
        let volumePath = volume.standardizedFileURL.path
        let leaving = folders.filter { IndexedFolder(id: $0.id, path: volumePath).contains(path: $0.path) }
        for folder in leaving {
            queuedScans.removeAll { $0 == folder.id }
            if currentScan?.folderID == folder.id { scanTask?.cancel() }
        }
    }

    /// Fills in which share each folder is on, and follows shares that macOS mounted under a
    /// different name (e.g. `/Volumes/Projects-1` instead of `/Volumes/Projects`).
    private func updateFolderLocations() {
        var mounted: [(url: URL, address: ServerAddress)]?
        for index in folders.indices {
            var folder = folders[index]
            if folder.isConnected {
                guard folder.serverAddress == nil, let location = ServerVolumes.location(of: folder.path) else { continue }
                folder.serverAddress = location.address
                folder.pathInShare = location.pathInShare
            } else {
                guard let address = folder.serverAddress else { continue }
                mounted = mounted ?? ServerVolumes.mounted()
                guard let volume = mounted?.first(where: { $0.address == address }) else { continue }
                let inShare = folder.pathInShare ?? ""
                let newPath = inShare.isEmpty ? volume.url.path : volume.url.appendingPathComponent(inShare).path
                guard newPath != folder.path, FileManager.default.fileExists(atPath: newPath) else { continue }
                folder.path = newPath
            }
            folders[index] = folder
        }
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
            let exclusions = exclusions
            scanTask = Task.detached(priority: .utility) { [weak self] in
                let result: Result<ScanOutcome, any Error>
                do {
                    let replacement = try store.beginReplacing(share: folder.shareKey, displayName: folder.name)
                    var unreadable: [String] = []
                    for try await batch in scanner.scan(root: folder.url, exclusions: exclusions) {
                        let becameSearchable = try replacement.insert(batch.records)
                        unreadable += batch.unreadableFolders
                        let found = replacement.insertedCount
                        await self?.scanMadeProgress(found: found, becameSearchable: becameSearchable)
                    }
                    try Task.checkCancellation()
                    try replacement.commit()
                    result = .success(ScanOutcome(itemCount: replacement.insertedCount, unreadableFolders: unreadable))
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

    private func scanFinished(_ folder: IndexedFolder, result: Result<ScanOutcome, any Error>) {
        scanTask = nil
        currentScan = nil
        switch result {
        case .success(let outcome):
            itemCounts[folder.id] = outcome.itemCount
            unreadableFolders[folder.id] = outcome.unreadableFolders.isEmpty ? nil : outcome.unreadableFolders
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index].lastIndexedAt = .now
            }
        case .failure(is CancellationError):
            break
        case .failure(ScanError.rootUnavailable):
            scanErrors[folder.id] = String(localized: "Not connected. Connect to the server in Finder, then rescan.")
        case .failure(ScanError.connectionLost):
            scanErrors[folder.id] = String(localized: "The connection to the server was lost while indexing. The previous list was kept.")
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

    func search(_ query: Query) async -> [SearchHit] {
        guard let store else { return [] }
        let results = await Task.detached(priority: .userInitiated) {
            (try? store.search(query)) ?? []
        }.value
        let foldersByKey = Dictionary(uniqueKeysWithValues: folders.map { ($0.shareKey, $0) })
        return results.compactMap { result in
            foldersByKey[result.share].map { SearchHit(result: result, folder: $0) }
        }
    }

    // MARK: Status

    /// One line about a folder: its progress, problem, or size and freshness.
    func statusDetail(for folder: IndexedFolder) -> String {
        if let scan = currentScan, scan.folderID == folder.id {
            return String(localized: "Indexing… \(scan.found.formatted()) found")
        }
        if isQueued(folder) { return String(localized: "Waiting to index…") }
        if let error = scanErrors[folder.id] { return error }
        guard let lastIndexed = folder.lastIndexedAt else { return String(localized: "Not indexed yet") }
        var detail = String(localized: "\((itemCounts[folder.id] ?? 0).formatted()) items · updated \(lastIndexed.formatted(.relative(presentation: .named)))")
        if let unreadable = unreadableFolders[folder.id] {
            detail += " · " + String(localized: "\(unreadable.count) folders couldn't be read")
        }
        return detail
    }

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

/// Saves the exclusion patterns in the user's preferences. New installs get the Windows Server defaults.
enum ExclusionStorage {
    private static let key = "exclusionPatterns"

    static func load() -> ExclusionRules {
        guard let patterns = UserDefaults.standard.stringArray(forKey: key) else { return .windowsServerDefaults }
        return ExclusionRules(patterns: patterns)
    }

    static func save(_ rules: ExclusionRules) {
        UserDefaults.standard.set(rules.patterns, forKey: key)
    }
}
