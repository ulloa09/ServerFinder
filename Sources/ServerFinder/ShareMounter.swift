import Foundation
import NetFS

/// Connects to a server share, like Finder's Go → Connect to Server. macOS shows its own
/// login window when it needs a password (or uses the one saved in the Keychain).
enum ShareMounter {
    struct Failure: Error {
        let isCancelled: Bool
    }

    /// Mounts `url` (e.g. `smb://admin@fileserver/Projects`) under /Volumes. Succeeds
    /// immediately if it's already mounted.
    static func mount(_ url: URL) async throws {
        let options = NSMutableDictionary()
        options[kNAUIOptionKey] = kNAUIOptionAllowUI
        let status: Int32 = await withCheckedContinuation { continuation in
            var request: AsyncRequestID?
            let started = NetFSMountURLAsync(
                url as CFURL, nil, nil, nil, options, nil, &request, .main
            ) { status, _, _ in
                continuation.resume(returning: status)
            }
            if started != 0 { continuation.resume(returning: started) }
        }
        switch status {
        case 0, EEXIST: return
        case ECANCELED, Int32(userCanceledErr): throw Failure(isCancelled: true)
        default: throw Failure(isCancelled: false)
        }
    }
}
