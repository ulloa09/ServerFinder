import Foundation
import Observation
import ServerFinderCore

struct ContentProgress: Equatable {
    var folderID: UUID
    var folderName: String
    var done: Int
    var total: Int
    /// Recognizing text in scanned PDFs, rather than reading documents.
    var isRecognizing = false
}

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

    /// For matches inside the file: the matching passage (see ``ContentResult/snippet``).
    var snippet: String?
    /// Its share wasn't mounted when the search ran; the result comes from the last scan.
    var isOffline = false

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
    /// Files whose text is never read or stored (they're still found by name).
    private(set) var neverRead: ExclusionRules {
        didSet { ExclusionStorage.saveNeverRead(neverRead) }
    }
    /// Folders the last scan couldn't read (no permission), relative to each indexed folder.
    private(set) var unreadableFolders: [UUID: [String]] = [:]
    /// Increases whenever newly indexed items become searchable, so open searches can refresh.
    private(set) var indexVersion = 0

    let store: IndexStore?
    let storeError: String?

    private let scanner = ShareScanner()
    private var scanTask: Task<Void, Never>?

    /// Reading document contents runs after name scans, one folder at a time.
    private(set) var contentProgress: ContentProgress?
    private var contentQueue: [UUID] = []
    /// Folders whose scanned PDFs wait for text recognition; runs only when nothing else is read.
    private var recognitionQueue: [UUID] = []
    private var contentTask: Task<Void, Never>?
    /// What to read, and whether to read at all (Settings → Contents).
    private(set) var contentSettings: ContentSettings {
        didSet { ContentSettings.save(contentSettings) }
    }
    /// Documents read per folder, by outcome.
    private(set) var contentCounts: [UUID: [ContentOutcome: Int]] = [:]

    init() {
        folders = IndexedFolderStorage.load()
        exclusions = ExclusionStorage.load()
        neverRead = ExclusionStorage.loadNeverRead()
        contentSettings = ContentSettings.load()
        do {
            store = try IndexStore(url: Self.indexURL)
            storeError = nil
        } catch {
            store = nil
            storeError = String(describing: error)
        }
        refreshCounts()
        refreshContentCounts()
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
        contentQueue.removeAll { $0 == folder.id }
        recognitionQueue.removeAll { $0 == folder.id }
        if contentProgress?.folderID == folder.id { contentTask?.cancel() }
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

    func setNeverReadPatterns(_ patterns: [String]) {
        neverRead = ExclusionRules(patterns: patterns)
        removeNeverReadContents()
    }

    func restoreDefaultNeverRead() {
        neverRead = .sensitiveDefaults
        removeNeverReadContents()
    }

    /// Deletes stored text of files the "never read" list matches, in every folder, right away
    /// (no need for the share to be connected: it only touches the local index).
    /// `then` runs afterwards, on the main actor.
    func removeNeverReadContents(then: (@MainActor () -> Void)? = nil) {
        guard let store else { then?(); return }
        let shares = folders.map(\.shareKey)
        let neverRead = neverRead
        let extensions = contentSettings.extensions
        Task.detached(priority: .userInitiated) { [weak self] in
            for share in shares {
                // A running name scan can hold the database for minutes: keep trying rather
                // than leaving private text behind.
                for attempt in 1...60 {
                    do {
                        let updates = try store.beginContentUpdates(share: share)
                        if try updates.removeStale(keepingExtensions: extensions, neverRead: neverRead) > 0 {
                            try updates.scrubDeletedText()
                        }
                        break
                    } catch {
                        guard attempt < 60 else { break }
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
            await self?.contentRemoved()
            await then?()
        }
    }

    private func contentRemoved() {
        indexVersion += 1
        refreshContentCounts()
    }

    // MARK: Content settings

    func updateContentSettings(_ change: (inout ContentSettings) -> Void) {
        let old = contentSettings
        var new = old
        change(&new)
        guard new != old else { return }
        contentSettings = new

        guard new.isEnabled else {
            // Stop reading; the text read so far is kept for when it's turned back on.
            contentQueue.removeAll()
            recognitionQueue.removeAll()
            contentTask?.cancel()
            indexVersion += 1
            return
        }
        if !new.readsScans {
            // Recognized text stays; only the remaining scans wait.
            recognitionQueue.removeAll()
            if contentProgress?.isRecognizing == true { contentTask?.cancel() }
        }
        if new.kinds != old.kinds {
            // Drop text of types turned off right away, then read types turned on.
            removeNeverReadContents { [weak self] in self?.readContentsOfConnectedFolders() }
        } else if !old.isEnabled || new.maxSizeMB > old.maxSizeMB || (new.readsScans && !old.readsScans) {
            readContentsOfConnectedFolders()
        }
        indexVersion += 1
    }

    /// Deletes every document's stored text from this Mac. Names stay; with content search on,
    /// documents are read again from scratch.
    func eraseAllContents() {
        guard let store else { return }
        contentQueue.removeAll()
        recognitionQueue.removeAll()
        contentTask?.cancel()
        Task.detached(priority: .userInitiated) { [weak self] in
            for attempt in 1...60 {
                do {
                    try store.eraseAllContents()
                    break
                } catch {
                    guard attempt < 60 else { break }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            await self?.contentsErased()
        }
    }

    private func contentsErased() {
        contentCounts = [:]
        indexVersion += 1
        readContentsOfConnectedFolders()
    }

    func readContentsOfConnectedFolders() {
        for folder in folders where folder.isConnected { enqueueContentReading(of: folder.id) }
    }

    func refreshContentCounts() {
        guard let store else { return }
        let folders = folders
        Task.detached(priority: .utility) { [weak self] in
            var counts: [UUID: [ContentOutcome: Int]] = [:]
            for folder in folders {
                counts[folder.id] = (try? store.contentCounts(share: folder.shareKey)) ?? [:]
            }
            await self?.setContentCounts(counts)
        }
    }

    private func setContentCounts(_ counts: [UUID: [ContentOutcome: Int]]) {
        contentCounts = counts
    }

    /// Totals over all folders.
    var totalContentCounts: [ContentOutcome: Int] {
        contentCounts.values.reduce(into: [:]) { total, counts in
            total.merge(counts, uniquingKeysWith: +)
        }
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

    /// Connects to the share `folder` is on, then returns where the folder is now.
    /// Throws ``ShareMounter/Failure`` when the share can't be reached or the login is cancelled.
    func connect(_ folder: IndexedFolder) async throws -> IndexedFolder {
        guard let mountURL = folders.first(where: { $0.id == folder.id })?.mountURL else {
            throw ShareMounter.Failure(isCancelled: false)
        }
        try await ShareMounter.mount(mountURL)
        updateFolderLocations()
        guard let current = folders.first(where: { $0.id == folder.id }), current.isConnected else {
            throw ShareMounter.Failure(isCancelled: false)
        }
        return current
    }

    /// A share is going away: stop scanning it, keeping the list from its last complete scan.
    func volumeWillUnmount(at volume: URL) {
        let volumePath = volume.standardizedFileURL.path
        let leaving = folders.filter { IndexedFolder(id: $0.id, path: volumePath).contains(path: $0.path) }
        for folder in leaving {
            queuedScans.removeAll { $0 == folder.id }
            if currentScan?.folderID == folder.id { scanTask?.cancel() }
            contentQueue.removeAll { $0 == folder.id }
            recognitionQueue.removeAll { $0 == folder.id }
            if contentProgress?.folderID == folder.id { contentTask?.cancel() }
        }
    }

    /// Fills in which share each folder is on, and follows shares that macOS mounted under a
    /// different name (e.g. `/Volumes/Projects-1` instead of `/Volumes/Projects`).
    private func updateFolderLocations() {
        var mounted: [(url: URL, address: ServerAddress)]?
        for index in folders.indices {
            var folder = folders[index]
            if folder.isConnected {
                guard folder.serverAddress == nil || folder.mountURL == nil,
                      let location = ServerVolumes.location(of: folder.path) else { continue }
                folder.serverAddress = location.address
                folder.pathInShare = location.pathInShare
                folder.mountURL = location.mountURL
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
            enqueueContentReading(of: folder.id)
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

    // MARK: Reading contents

    private func enqueueContentReading(of folderID: UUID) {
        guard contentSettings.isEnabled, !contentQueue.contains(folderID) else { return }
        if let current = contentProgress {
            if current.isRecognizing {
                // Normal reading goes first; recognition picks up again afterwards.
                contentTask?.cancel()
            } else if current.folderID == folderID {
                return
            }
        }
        contentQueue.append(folderID)
        startNextContentReadingIfIdle()
    }

    private func enqueueRecognition(of folderID: UUID) {
        guard contentSettings.readsScans, !recognitionQueue.contains(folderID) else { return }
        recognitionQueue.append(folderID)
        startNextContentReadingIfIdle()
    }

    private var isNameScanRunning: Bool { currentScan != nil }

    private func startNextContentReadingIfIdle() {
        guard contentTask == nil, let store else { return }
        while !contentQueue.isEmpty {
            let folderID = contentQueue.removeFirst()
            guard let folder = folders.first(where: { $0.id == folderID }), folder.isConnected else { continue }
            contentProgress = ContentProgress(folderID: folder.id, folderName: folder.name, done: 0, total: 0)
            let neverRead = neverRead
            let settings = contentSettings
            contentTask = Task.detached(priority: .utility) { [weak self] in
                let finishedNormally: Bool
                do {
                    try await Self.readContents(of: folder, store: store, settings: settings, neverRead: neverRead, model: self)
                    finishedNormally = true
                } catch {
                    finishedNormally = false
                }
                await self?.contentReadingFinished(folder, completed: finishedNormally)
            }
            return
        }
        while !recognitionQueue.isEmpty {
            let folderID = recognitionQueue.removeFirst()
            guard contentSettings.readsScans,
                  let folder = folders.first(where: { $0.id == folderID }), folder.isConnected else { continue }
            contentProgress = ContentProgress(folderID: folder.id, folderName: folder.name, done: 0, total: 0, isRecognizing: true)
            let neverRead = neverRead
            let settings = contentSettings
            contentTask = Task.detached(priority: .background) { [weak self] in
                let finishedNormally: Bool
                do {
                    try await Self.recognizeScans(of: folder, store: store, settings: settings, neverRead: neverRead, model: self)
                    finishedNormally = true
                } catch {
                    finishedNormally = false
                }
                await self?.recognitionFinished(folder, completed: finishedNormally)
            }
            return
        }
    }

    /// Reads every new or changed document of `folder`, saving each result as it goes.
    /// Stops (throwing) if cancelled or if the share disappears; the next pass continues from there.
    private nonisolated static func readContents(
        of folder: IndexedFolder, store: IndexStore, settings: ContentSettings, neverRead: ExclusionRules, model: AppModel?
    ) async throws {
        let updates = try store.beginContentUpdates(share: folder.shareKey)
        try updates.removeStale(keepingExtensions: settings.extensions, neverRead: neverRead)
        let pending = try updates.pendingFiles(extensions: settings.extensions, maxSize: settings.maxSize, neverRead: neverRead)
        await model?.contentMadeProgress(done: 0, total: pending.count, becameSearchable: false)

        var lastReport = Date.distantPast
        for (index, file) in pending.enumerated() {
            try Task.checkCancellation()
            // Name scans come first: they're what makes new files findable at all.
            while await model?.isNameScanRunning == true {
                try await Task.sleep(for: .seconds(2))
            }
            let url = folder.url.appendingPathComponent(file.relativePath)
            do {
                switch try TextExtractor.text(of: url) {
                case .text(let text): try updates.record(file, outcome: .indexed, text: text)
                case .needsOCR: try updates.record(file, outcome: .needsOCR)
                case .unsupported: try updates.record(file, outcome: .failed)
                }
            } catch let error as ExtractionError {
                // A damaged file — unless the whole share went away, which isn't the file's fault.
                guard FileManager.default.fileExists(atPath: folder.path) else { throw error }
                try updates.record(file, outcome: .failed)
            } catch {
                guard FileManager.default.fileExists(atPath: folder.path) else { throw error }
                if (error as NSError).domain == NSCocoaErrorDomain {
                    try updates.record(file, outcome: .failed) // e.g. no permission to read the file
                } else {
                    throw error // database trouble: stop and retry on the next pass
                }
            }
            if Date().timeIntervalSince(lastReport) > 0.5 || index == pending.count - 1 {
                lastReport = Date()
                await model?.contentMadeProgress(done: index + 1, total: pending.count, becameSearchable: true)
            }
        }
    }

    /// Recognizes the text of `folder`'s scanned PDFs, saving each one as it goes. Waits while a
    /// name scan runs, in Low Power Mode or when the Mac is hot; stops (throwing) if cancelled
    /// or if the share disappears.
    private nonisolated static func recognizeScans(
        of folder: IndexedFolder, store: IndexStore, settings: ContentSettings, neverRead: ExclusionRules, model: AppModel?
    ) async throws {
        let updates = try store.beginContentUpdates(share: folder.shareKey)
        let pending = try updates.pendingScans(maxSize: settings.maxSize, neverRead: neverRead)
        await model?.contentMadeProgress(done: 0, total: pending.count, becameSearchable: false)

        for (index, file) in pending.enumerated() {
            try Task.checkCancellation()
            while await model?.isNameScanRunning == true || shouldPauseRecognition {
                try await Task.sleep(for: .seconds(5))
            }
            let url = folder.url.appendingPathComponent(file.relativePath)
            do {
                let text = try OCRReader.text(ofScannedPDF: url)
                try updates.record(file, outcome: .recognized, text: text)
            } catch let error as ExtractionError {
                guard FileManager.default.fileExists(atPath: folder.path) else { throw error }
                try updates.record(file, outcome: .failed)
            } catch {
                guard FileManager.default.fileExists(atPath: folder.path) else { throw error }
                if (error as NSError).domain == NSCocoaErrorDomain {
                    try updates.record(file, outcome: .failed)
                } else {
                    throw error // cancelled, or database trouble: retry on a later pass
                }
            }
            await model?.contentMadeProgress(done: index + 1, total: pending.count, becameSearchable: true)
        }
    }

    /// Text recognition keeps several cores busy; leave the Mac alone when it's saving power or hot.
    private nonisolated static var shouldPauseRecognition: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    private func contentMadeProgress(done: Int, total: Int, becameSearchable: Bool) {
        contentProgress?.done = done
        contentProgress?.total = total
        if becameSearchable { indexVersion += 1 }
    }

    private func contentReadingFinished(_ folder: IndexedFolder, completed: Bool) {
        contentTask = nil
        contentProgress = nil
        indexVersion += 1
        refreshContentCounts()
        if completed { enqueueRecognition(of: folder.id) }
        startNextContentReadingIfIdle()
    }

    private func recognitionFinished(_ folder: IndexedFolder, completed: Bool) {
        contentTask = nil
        contentProgress = nil
        indexVersion += 1
        refreshContentCounts()
        // Interrupted to let normal reading go first: try again afterwards.
        if !completed, !contentQueue.isEmpty, folders.contains(where: { $0.id == folder.id }) {
            enqueueRecognition(of: folder.id)
        }
        startNextContentReadingIfIdle()
    }

    // MARK: Searching

    func search(_ query: Query) async -> [SearchHit] {
        guard let store else { return [] }
        let results = await Task.detached(priority: .userInitiated) {
            (try? store.search(query)) ?? []
        }.value
        let foldersByKey = Dictionary(uniqueKeysWithValues: folders.map { ($0.shareKey, $0) })
        let offline = offlineFolderIDs
        return results.compactMap { result in
            foldersByKey[result.share].map { SearchHit(result: result, folder: $0, isOffline: offline.contains($0.id)) }
        }
    }

    /// Documents whose text contains every word of `query`.
    func searchContents(_ query: Query) async -> [SearchHit] {
        guard let store, contentSettings.isEnabled, !query.terms.isEmpty else { return [] }
        let results = await Task.detached(priority: .userInitiated) {
            (try? store.searchContent(query)) ?? []
        }.value
        let foldersByKey = Dictionary(uniqueKeysWithValues: folders.map { ($0.shareKey, $0) })
        let offline = offlineFolderIDs
        return results.compactMap { match in
            foldersByKey[match.result.share].map {
                SearchHit(result: match.result, folder: $0, snippet: match.snippet, isOffline: offline.contains($0.id))
            }
        }
    }

    private var offlineFolderIDs: Set<UUID> {
        Set(folders.filter { !$0.isConnected }.map(\.id))
    }

    // MARK: Status

    /// One line about a folder: its progress, problem, or size and freshness.
    func statusDetail(for folder: IndexedFolder) -> String {
        if let scan = currentScan, scan.folderID == folder.id {
            return String(localized: "Indexing… \(scan.found.formatted()) found")
        }
        if isQueued(folder) { return String(localized: "Waiting to index…") }
        if let reading = contentProgress, reading.folderID == folder.id, reading.total > 0 {
            if reading.isRecognizing {
                return String(localized: "Recognizing text in scanned PDFs… \(reading.done.formatted()) of \(reading.total.formatted())")
            }
            return String(localized: "Reading documents… \(reading.done.formatted()) of \(reading.total.formatted())")
        }
        if let error = scanErrors[folder.id] { return error }
        guard let lastIndexed = folder.lastIndexedAt else { return String(localized: "Not indexed yet") }
        var detail = String(localized: "\((itemCounts[folder.id] ?? 0).formatted()) items · updated \(lastIndexed.formatted(.relative(presentation: .named)))")
        if let unreadable = unreadableFolders[folder.id] {
            detail += " · " + String(localized: "\(unreadable.count) folders couldn't be read")
        }
        return detail
    }

    /// What document reading is doing, while it runs.
    var contentStatusText: String? {
        guard let reading = contentProgress, reading.total > 0 else { return nil }
        if reading.isRecognizing {
            return String(localized: "Recognizing text in scanned PDFs in “\(reading.folderName)”… \(reading.done.formatted()) of \(reading.total.formatted())")
        }
        return String(localized: "Reading documents in “\(reading.folderName)”… \(reading.done.formatted()) of \(reading.total.formatted())")
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
        if let contentStatusText { return contentStatusText }
        if folders.isEmpty {
            return String(localized: "No folders selected yet")
        }
        return String(localized: "\(totalItems.formatted()) items indexed")
    }
}

/// Saves the exclusion patterns in the user's preferences. New installs get the Windows Server defaults.
enum ExclusionStorage {
    private static let key = "exclusionPatterns"
    private static let neverReadKey = "neverReadPatterns"

    static func loadNeverRead() -> ExclusionRules {
        guard let patterns = UserDefaults.standard.stringArray(forKey: neverReadKey) else { return .sensitiveDefaults }
        return ExclusionRules(patterns: patterns)
    }

    static func saveNeverRead(_ rules: ExclusionRules) {
        UserDefaults.standard.set(rules.patterns, forKey: neverReadKey)
    }

    static func load() -> ExclusionRules {
        guard let patterns = UserDefaults.standard.stringArray(forKey: key) else { return .windowsServerDefaults }
        return ExclusionRules(patterns: patterns)
    }

    static func save(_ rules: ExclusionRules) {
        UserDefaults.standard.set(rules.patterns, forKey: key)
    }
}

/// Settings → Contents. Saved in the user's preferences.
extension Dictionary where Key == ContentOutcome, Value == Int {
    /// Documents with text that can be searched: read normally or recognized from scans.
    var searchable: Int { (self[.indexed] ?? 0) + (self[.recognized] ?? 0) }
}

struct ContentSettings: Codable, Equatable {
    var isEnabled = true
    var kinds: Set<DocumentKind> = Set(DocumentKind.allCases)
    /// Text recognition for scanned PDFs.
    var recognizesScans = true
    var maxSizeMB = 20
    /// The kinds this version offered when the settings were saved, so a kind added later starts on.
    private var knownKinds = Set(DocumentKind.allCases)

    static let sizeChoicesMB = [5, 10, 20, 50, 100]

    var extensions: Set<String> { DocumentKind.extensions(of: kinds) }
    var maxSize: Int64 { Int64(maxSizeMB) * 1_024 * 1_024 }
    var readsScans: Bool { isEnabled && recognizesScans && kinds.contains(.pdf) }

    private static let key = "contentSettings"

    static func load() -> ContentSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ContentSettings.self, from: data)
        else { return ContentSettings() }
        return settings
    }

    static func save(_ settings: ContentSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension ContentSettings {
    /// Settings saved by an older version keep their choices; values they lack get the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ContentSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        recognizesScans = try container.decodeIfPresent(Bool.self, forKey: .recognizesScans) ?? defaults.recognizesScans
        maxSizeMB = try container.decodeIfPresent(Int.self, forKey: .maxSizeMB) ?? defaults.maxSizeMB
        // Saved before knownKinds existed: everything but Excel was offered then.
        let known = try container.decodeIfPresent(Set<DocumentKind>.self, forKey: .knownKinds)
            ?? [.pdf, .word, .powerPoint, .text, .xml]
        let saved = try container.decodeIfPresent(Set<DocumentKind>.self, forKey: .kinds) ?? defaults.kinds
        kinds = saved.union(defaults.knownKinds.subtracting(known))
    }
}

