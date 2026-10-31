
import Foundation
import BackgroundTasks
import os

private let log = Logger(subsystem: "com.openplaudit.mobile", category: "background")

enum BackgroundSync {
    static let refreshID = "com.openplaudit.mobile.refresh"
    static let processingID = "com.openplaudit.mobile.processing"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID,
                                        using: nil) { task in
            handle(task, budget: 25, maxBytes: 1_500_000)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID,
                                        using: nil) { task in
            handle(task, budget: 240, maxBytes: 40_000_000)
        }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(refresh) }
        catch { log.debug("refresh schedule: \(error.localizedDescription)") }

        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do { try BGTaskScheduler.shared.submit(processing) }
        catch { log.debug("processing schedule: \(error.localizedDescription)") }
    }

    private static func handle(_ task: BGTask, budget: TimeInterval,
                               maxBytes: Int) {
        schedule()
        nonisolated(unsafe) let bgTask = task
        let work = Task { @MainActor in
            let model = DeviceSyncModel()
            let ok = await model.syncInBackground(timeBudget: budget,
                                                  maxRecordingBytes: maxBytes)
            bgTask.setTaskCompleted(success: ok)
        }
        bgTask.expirationHandler = {
            log.info("background window expired")
            work.cancel()
        }
    }
}
