import Foundation

public enum ScanError: Error, Equatable {
    /// The root folder doesn't exist or isn't a folder (usually: the share isn't mounted).
    case rootUnavailable(path: String)
    /// The server stopped answering during the scan, so the results would be incomplete.
    case connectionLost(path: String)
}

/// Part of a scan's output.
public struct ScanBatch: Sendable {
    public var records: [FileRecord]
    /// Folders that couldn't be read (e.g. no permission), relative to the root. Their
    /// contents are missing from the scan; everything else is complete.
    public var unreadableFolders: [String]

    public init(records: [FileRecord], unreadableFolders: [String] = []) {
        self.records = records
        self.unreadableFolders = unreadableFolders
    }
}

/// Walks a folder tree and emits every file and folder in it, in batches.
///
/// Only reads from the file system. Hidden files and the contents of packages are skipped.
/// Folders that can't be read are skipped and reported; losing the connection to the server
/// fails the scan, so an incomplete list never replaces a complete one.
public struct ShareScanner: Sendable {
    public var batchSize: Int
    /// How many folders are listed at the same time.
    public var concurrency: Int

    /// Chosen from timings over Wi-Fi to a Windows Server share (see issue #10).
    public static let defaultConcurrency = 8

    public init(batchSize: Int = 500, concurrency: Int = defaultConcurrency) {
        self.batchSize = batchSize
        self.concurrency = concurrency
    }

    /// Scans `root` on a background thread, leaving out what `exclusions` matches.
    /// Cancelling the consuming task stops the scan.
    public func scan(root: URL, exclusions: ExclusionRules = .none) -> AsyncThrowingStream<ScanBatch, any Error> {
        let batchSize = batchSize
        let concurrency = concurrency
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try Self.walk(root: root, exclusions: exclusions, batchSize: batchSize, concurrency: concurrency) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    fileprivate static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// Errors that mean the server is gone, as opposed to one folder being off-limits.
    private static let connectionErrors: Set<Int32> = [
        ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED,
        EHOSTDOWN, EHOSTUNREACH,
    ]

    /// Walks the tree, listing up to `concurrency` folders at once: over the network each
    /// listing mostly waits for the server, so several in flight hide that wait. Everything
    /// else (filtering, batching, `emit`) happens on the calling thread.
    ///
    /// The listings run on the scanner's own threads, not on Dispatch: this function blocks
    /// while it waits for them, and it's usually called from a Swift concurrency thread. On a
    /// Mac with few cores, blocked callers can use up the threads Dispatch would hand out, and
    /// the listings would then never start.
    static func walk(
        root: URL, exclusions: ExclusionRules = .none, batchSize: Int, concurrency: Int = defaultConcurrency,
        emit: (ScanBatch) -> Void
    ) throws {
        let root = root.standardizedFileURL
        guard isFolder(root) else { throw ScanError.rootUnavailable(path: root.path) }

        let listings = ListingQueue(root: root, workerLimit: max(concurrency, 1))
        defer { listings.stop() }
        // Folders waiting to be listed, by path relative to the root ("" is the root).
        var waiting: [String] = [""]
        var inFlight = 0
        var batch: [FileRecord] = []
        batch.reserveCapacity(batchSize)
        var unreadable: [String] = []

        func flush() {
            guard !batch.isEmpty || !unreadable.isEmpty else { return }
            emit(ScanBatch(records: batch, unreadableFolders: unreadable))
            batch.removeAll(keepingCapacity: true)
            unreadable.removeAll()
        }

        while !waiting.isEmpty || inFlight > 0 {
            try Task.checkCancellation()
            while inFlight < max(concurrency, 1), let folder = waiting.popLast() {
                inFlight += 1
                listings.request(folder)
            }
            let listing = listings.next()
            inFlight -= 1

            let children: [URL]
            switch listing.result {
            case .success(let urls):
                children = urls
            case .failure(let error):
                // Other errors (e.g. EIO) can come from one bad folder or from a lost share:
                // the root folder still being there tells them apart.
                if connectionErrors.contains(posixCode(of: error)) || !isFolder(root) {
                    throw ScanError.connectionLost(path: root.path)
                }
                if listing.folder.isEmpty { throw ScanError.rootUnavailable(path: root.path) }
                unreadable.append(listing.folder)
                continue
            }

            let keySet = Set(resourceKeys)
            for url in children {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                let name = values.name ?? url.lastPathComponent
                let isDirectory = values.isDirectory ?? false
                let relativePath = listing.folder.isEmpty ? name : listing.folder + "/" + name
                if exclusions.excludes(name: name, relativePath: relativePath) { continue }
                // Packages (e.g. .app, .rtfd) are listed as one item, without their contents.
                if isDirectory && values.isPackage != true { waiting.append(relativePath) }
                batch.append(FileRecord(
                    relativePath: relativePath,
                    name: name,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                ))
                if batch.count >= batchSize { flush() }
            }
        }
        try Task.checkCancellation()

        // If the share disappeared mid-scan (unmounted, Wi-Fi dropped), listings may have
        // ended early without a clear error. Don't let a partial list pass as complete.
        if !isFolder(root) {
            throw ScanError.connectionLost(path: root.path)
        }
        flush()
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func posixCode(of error: any Error) -> Int32 {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return posixCode(of: underlying)
        }
        return 0
    }
}

/// One folder's contents, or why it couldn't be listed.
private struct Listing: @unchecked Sendable {
    let folder: String
    let result: Result<[URL], any Error>
}

/// Lists folders on a few threads of its own and hands the results to the walk.
private final class ListingQueue: @unchecked Sendable {
    private let root: URL
    private let workerLimit: Int
    private let condition = NSCondition()
    private var requested: [String] = []
    private var done: [Listing] = []
    private var workers = 0
    private var idleWorkers = 0
    private var stopped = false

    init(root: URL, workerLimit: Int) {
        self.root = root
        self.workerLimit = workerLimit
    }

    /// Asks for `folder` (relative to the root) to be listed. Starts another thread if all
    /// the current ones are busy and the limit allows it.
    func request(_ folder: String) {
        condition.lock()
        requested.append(folder)
        let startWorker = idleWorkers == 0 && workers < workerLimit
        if startWorker { workers += 1 }
        condition.broadcast()
        condition.unlock()

        if startWorker {
            let thread = Thread { [self] in work() }
            thread.name = "ShareScanner.listing"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// Waits for the next finished listing.
    func next() -> Listing {
        condition.lock()
        defer { condition.unlock() }
        while done.isEmpty { condition.wait() }
        return done.removeFirst()
    }

    /// Lets the threads end once they finish the listing they're on.
    func stop() {
        condition.lock()
        stopped = true
        requested.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    private func work() {
        while let folder = nextRequest() {
            let url = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            let result = Result {
                try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: ShareScanner.resourceKeys, options: [.skipsHiddenFiles]
                )
            }
            condition.lock()
            done.append(Listing(folder: folder, result: result))
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The next folder to list, or nil once the walk is over.
    private func nextRequest() -> String? {
        condition.lock()
        defer { condition.unlock() }
        idleWorkers += 1
        defer { idleWorkers -= 1 }
        while requested.isEmpty && !stopped { condition.wait() }
        if stopped {
            workers -= 1
            return nil
        }
        return requested.removeFirst()
    }
}
