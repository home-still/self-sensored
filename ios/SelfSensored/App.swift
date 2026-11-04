import HealthKit
import SwiftUI

@main
struct SelfSensoredApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task {
                    // Hydrate banner state from on-disk queue snapshot before
                    // the first sync attempt so a previously-stalled state
                    // surfaces immediately on cold start.
                    await SyncEngine.shared.refreshQueueSnapshot()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Foregrounding is the single retry trigger: opening the app
            // drains the queue. No timer, no fallback.
            if newPhase == .active {
                Task { await SyncEngine.shared.syncAll() }
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The XCTest harness boots the app inside the test runner — skip
        // HealthKit setup there to avoid `_throwIfAuthorizationDisallowedForSharing`
        // crashing on a simulator without a signed entitlement.
        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        // Force full re-sync on this build (reset anchors once)
        let resetKey = "anchor_reset_v6_routes"
        if !UserDefaults.standard.bool(forKey: resetKey) {
            // Reset workout anchor so routes get synced on next run
            HKAnchorStore.shared.remove(for: HKSampleType.workoutType())
            UserDefaults.standard.set(true, forKey: resetKey)
        }

        // Start the failure-notification scheduler. Listens for
        // .healthSyncAuthExpired / .healthSyncFailed posted by APIClient
        // and SyncEngine and surfaces them as local notifications.
        SyncNotificationCenter.shared.start()

        Task {
            await HKManager.shared.requestAuthorization()
            HKBackgroundDelivery.shared.registerAll()
        }
        return true
    }
}
