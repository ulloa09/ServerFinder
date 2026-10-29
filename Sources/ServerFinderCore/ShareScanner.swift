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

    public init(batchSize: Int = 500) {
        self.batchSize = batchSize
    }

    /// Scans `root` on a background thread. Cancelling the consuming task stops the scan.
    public func scan(root: URL) -> AsyncThrowingStream<ScanBatch, any Error> {
        let batchSize = batchSize
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try Self.walk(root: root, batchSize: batchSize) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// Errors that mean the server is gone, as opposed to one folder being off-limits.
    private static let connectionErrors: Set<Int32> = [
        ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED,
        EHOSTDOWN, EHOSTUNREACH,
    ]

    static func walk(root: URL, batchSize: Int, emit: (ScanBatch) -> Void) throws {
        let root = root.standardizedFileURL
        guard isFolder(root) else { throw ScanError.rootUnavailable(path: root.path) }

        let problems = ProblemLog(root: root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // Other errors (e.g. EIO) can come from one bad item or from a lost share:
                // the root folder still being there tells them apart.
                if connectionErrors.contains(posixCode(of: error)) || !isFolder(root) {
                    problems.connectionLost = true
                    return false // stop: everything after this would be missing
                }
                problems.unreadable(url)
                return true
            }
        ) else {
            throw ScanError.rootUnavailable(path: root.path)
        }

        let keySet = Set(resourceKeys)
        var batch: [FileRecord] = []
        batch.reserveCapacity(batchSize)
        // Names of the folders above the current item, by depth. Building relative paths from
        // these avoids comparing path prefixes, which differ for symlinked roots (/var vs /private/var).
        var ancestors: [String] = []

        func flush() {
            let unreadable = problems.takeUnreadable()
            guard !batch.isEmpty || !unreadable.isEmpty else { return }
            emit(ScanBatch(records: batch, unreadableFolders: unreadable))
            batch.removeAll(keepingCapacity: true)
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            let name = values.name ?? url.lastPathComponent
            let isDirectory = values.isDirectory ?? false
            ancestors.removeSubrange(min(enumerator.level - 1, ancestors.count)...)
            let relativePath = (ancestors + [name]).joined(separator: "/")
            if isDirectory { ancestors.append(name) }
            batch.append(FileRecord(
                relativePath: relativePath,
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
            if batch.count >= batchSize { flush() }
        }
        try Task.checkCancellation()

        // If the share disappeared mid-scan (unmounted, Wi-Fi dropped), the walk may have ended
        // early without a clear error. Don't let a partial list pass as complete.
        if problems.connectionLost || !isFolder(root) {
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

/// Collects problems reported by the directory enumerator while it walks.
private final class ProblemLog {
    private let rootPaths: [String]
    private var pendingUnreadable: [String] = []
    var connectionLost = false

    init(root: URL) {
        // The enumerator may report either spelling of a symlinked root (/var vs /private/var).
        rootPaths = Set([root.path, root.resolvingSymlinksInPath().path, "/private" + root.path])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    func unreadable(_ url: URL) {
        let path = url.standardizedFileURL.path
        let relative = rootPaths.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) } ?? path
        pendingUnreadable.append(relative)
    }

    func takeUnreadable() -> [String] {
        defer { pendingUnreadable.removeAll() }
        return pendingUnreadable
    }
}
