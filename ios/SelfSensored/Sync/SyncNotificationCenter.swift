import Foundation
import UserNotifications

/// Listens for `.healthSyncAuthExpired` and `.healthSyncFailed` and turns
/// them into local user notifications. Rate-limited to one notification per
/// kind per `cooldown` so a flurry of background sync errors doesn't spam
/// the lock screen — the user just needs *one* loud signal that sync has
/// stopped working.
@MainActor
final class SyncNotificationCenter {
    static let shared = SyncNotificationCenter()

    /// Minimum gap between repeat notifications of the same kind. 24 h means
    /// a stuck install fires once a day, which is enough to be noticed and
    /// not enough to feel like spam.
    private let cooldown: TimeInterval = 24 * 60 * 60

    private let lastPostedKey = "sync_notification_last_posted"

    private enum Kind: String {
        case authExpired
        case failed

        var title: String {
            switch self {
            case .authExpired: return "Self Sensored needs you to sign in"
            case .failed: return "Self Sensored paused"
            }
        }

        var body: String {
            switch self {
            case .authExpired:
                return "Your session expired. Open Self Sensored and log in again to resume syncing."
            case .failed:
                return "Background sync failed. Open Self Sensored to retry."
            }
        }
    }

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Request notification permission and start listening for failure
    /// notifications. Call once at app launch.
    func start() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if let error {
                print("UN auth request failed: \(error)")
            } else {
                print("UN auth granted=\(granted)")
            }
        }

        let nc = NotificationCenter.default
        // Observer callbacks are dispatched on `.main` so we're already on
        // the main thread, but the closure type isn't @MainActor-isolated.
        // `assumeIsolated` formalizes the invariant for the type-checker.
        observers.append(nc.addObserver(
            forName: .healthSyncAuthExpired, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.post(.authExpired)
            }
        })
        observers.append(nc.addObserver(
            forName: .healthSyncFailed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.maybePostStalled()
            }
        })
    }

    /// Only post a "paused" notification if SyncQueue itself thinks we're
    /// stalled (queue non-empty AND no successes in 24 h). A single transient
    /// network error shouldn't bother the user.
    private func maybePostStalled() {
        Task {
            let snap = await SyncQueue.shared.snapshot()
            if snap.isStalled {
                await MainActor.run { self.post(.failed) }
            }
        }
    }

    private func post(_ kind: Kind) {
        let key = "\(lastPostedKey).\(kind.rawValue)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < cooldown {
            return
        }
        UserDefaults.standard.set(now, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = kind.body
        content.sound = .default

        // Trigger nil = deliver immediately. iOS still suppresses while the
        // app is foreground unless `willPresent` returns options — this is
        // fine because the in-app banner covers the foreground case.
        let request = UNNotificationRequest(
            identifier: "selfsensored.\(kind.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("UN add failed for \(kind.rawValue): \(error)")
            }
        }
    }
}
