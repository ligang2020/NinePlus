import BackgroundTasks
import Foundation
import WidgetKit

enum NinebotBackgroundTaskManager {
    static let refreshIdentifier = "com.example.NineBotPlus.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func scheduleRefresh(after interval: TimeInterval = defaultRefreshInterval) {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The system may reject duplicate or temporarily unavailable requests.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh()

        let operation = Task {
            await refreshDashboard(source: "Background")
        }

        task.expirationHandler = {
            operation.cancel()
        }

        Task {
            let success = await operation.value
            task.setTaskCompleted(success: success)
        }
    }

    @discardableResult
    static func refreshDashboard(source: String) async -> Bool {
        let startedAt = Date()
        let store = NinebotSharedStore()
        let cached = store.loadDashboard()
        let configuration = store.loadConfiguration() ?? NinebotServerConfiguration(baseURLString: "", bearerToken: "")

        guard configuration.isUsable else {
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: source,
                operation: "后台刷新",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: "未配置数据源"
            ))
            return false
        }

        do {
            let dashboard = try await NinebotServerClient(configuration: configuration)
                .fetchDashboard(selectedSN: cached?.selectedSN)
            let archivedDashboard = store.saveDashboard(dashboard)
            NinebotChargingLiveActivityManager.sync(with: archivedDashboard)
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: source,
                operation: "后台刷新",
                startedAt: startedAt,
                endedAt: Date(),
                success: true,
                message: archivedDashboard.primaryVehicle?.vehicle.name
            ))
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            store.saveLastError(error.localizedDescription)
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: source,
                operation: "后台刷新",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: error.localizedDescription
            ))
            return false
        }
    }

    private static var defaultRefreshInterval: TimeInterval {
        let state = NinebotSharedStore().loadDashboard()?.primaryVehicle?.state
        if state?.isCharging == true, state?.isFullyCharged != true {
            return 15 * 60
        }
        if state?.isLocked == false || state?.isPoweredOn == true {
            return 20 * 60
        }
        return 30 * 60
    }
}
