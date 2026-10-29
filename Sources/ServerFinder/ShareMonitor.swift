import AppKit

/// Keeps the index fresh without the user asking: scans a share when it connects,
/// stops when it disconnects, and rescans folders on schedule while they stay connected.
@MainActor
final class ShareMonitor {
    private let model: AppModel
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.didMountNotification) { model, volume in
            model.volumeDidMount(at: volume)
        }
        observe(center, NSWorkspace.willUnmountNotification) { model, volume in
            model.volumeWillUnmount(at: volume)
        }
        // After sleep, shares may have reconnected and scheduled rescans may be overdue.
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.scanDueFolders() }
        }.store(in: &observers)

        // Checking every few minutes is cheap: it only looks at dates until a folder is due.
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.scanDueFolders() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor @Sendable (AppModel, URL) -> Void
    ) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self.model, volume)
            }
        }.store(in: &observers)
    }
}

private extension NSObjectProtocol {
    func store(in observers: inout [NSObjectProtocol]) {
        observers.append(self)
    }
}
