import AppIntents
import Foundation
import WidgetKit

private enum NinebotWidgetVehicleAction {
    case bell
    case openBucket
    case engineStart
    case engineStop

    var title: String {
        switch self {
        case .bell: return "寻车"
        case .openBucket: return "开座桶"
        case .engineStart: return "开锁"
        case .engineStop: return "关锁"
        }
    }
}

struct NinebotWidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新车况"
    static var description = IntentDescription("刷新 NineBot+ 当前车辆的车况。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vehicleName = try await NinebotWidgetIntentRunner.refreshDashboard()
        return .result(dialog: "\(vehicleName) 车况已刷新")
    }
}

struct NinebotWidgetRingBellIntent: AppIntent {
    static var title: LocalizedStringResource = "寻车鸣笛"
    static var description = IntentDescription("让当前车辆发出寻车提示音。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vehicleName = try await NinebotWidgetIntentRunner.perform(.bell)
        return .result(dialog: "\(vehicleName) 寻车指令已发送")
    }
}

struct NinebotWidgetOpenBucketIntent: AppIntent {
    static var title: LocalizedStringResource = "打开座桶"
    static var description = IntentDescription("打开当前车辆的座桶。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vehicleName = try await NinebotWidgetIntentRunner.perform(.openBucket)
        return .result(dialog: "\(vehicleName) 开座桶指令已发送")
    }
}

struct NinebotWidgetEngineStartIntent: AppIntent {
    static var title: LocalizedStringResource = "滑动开锁"
    static var description = IntentDescription("让当前车辆进入上电/解锁状态。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vehicleName = try await NinebotWidgetIntentRunner.perform(.engineStart)
        return .result(dialog: "\(vehicleName) 开锁指令已发送")
    }
}

struct NinebotWidgetEngineStopIntent: AppIntent {
    static var title: LocalizedStringResource = "滑动关锁"
    static var description = IntentDescription("让当前车辆进入熄火/锁车状态。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vehicleName = try await NinebotWidgetIntentRunner.perform(.engineStop)
        return .result(dialog: "\(vehicleName) 关锁指令已发送")
    }
}

private enum NinebotWidgetIntentRunner {
    private static let refreshSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func refreshDashboard() async throws -> String {
        let startedAt = Date()
        let store = NinebotSharedStore()
        do {
            let client = try client(from: store)
            let cached = store.loadDashboard()
            let dashboard = try await client.fetchDashboard(selectedSN: cached?.selectedSN)
            let archivedDashboard = store.saveDashboard(dashboard)
            recordWidgetEvent(store: store, startedAt: startedAt, operation: "刷新车况", success: true, message: archivedDashboard.primaryVehicle?.vehicle.name)
            WidgetCenter.shared.reloadAllTimelines()
            return archivedDashboard.primaryVehicle?.vehicle.name ?? "九号"
        } catch {
            recordWidgetEvent(store: store, startedAt: startedAt, operation: "刷新车况", success: false, message: error.localizedDescription)
            throw error
        }
    }

    static func perform(_ action: NinebotWidgetVehicleAction) async throws -> String {
        let startedAt = Date()
        let store = NinebotSharedStore()
        do {
            let client = try client(from: store)
            let dashboard = try await dashboardForOperation(store: store, client: client)
            guard let vehicle = dashboard.primaryVehicle?.vehicle else {
                throw NinebotWidgetIntentError.missingVehicle
            }

            switch action {
            case .bell:
                _ = try await client.ringBell(sn: vehicle.sn)
            case .openBucket:
                _ = try await client.openBucket(sn: vehicle.sn)
            case .engineStart:
                _ = try await client.engineStart(sn: vehicle.sn)
            case .engineStop:
                _ = try await client.engineStop(sn: vehicle.sn)
            }

            let refreshed = try await client.fetchDashboard(selectedSN: vehicle.sn)
            store.saveDashboard(refreshed)
            recordWidgetEvent(store: store, startedAt: startedAt, operation: action.title, success: true, message: vehicle.name)
            WidgetCenter.shared.reloadAllTimelines()
            return vehicle.name
        } catch {
            recordWidgetEvent(store: store, startedAt: startedAt, operation: action.title, success: false, message: error.localizedDescription)
            throw error
        }
    }

    private static func client(from store: NinebotSharedStore) throws -> NinebotServerClient {
        let configuration = store.loadConfiguration() ?? NinebotServerConfiguration(baseURLString: "", bearerToken: "")
        guard configuration.isUsable else {
            throw NinebotWidgetIntentError.missingConfiguration
        }
        return NinebotServerClient(configuration: configuration, session: refreshSession)
    }

    private static func dashboardForOperation(
        store: NinebotSharedStore,
        client: NinebotServerClient
    ) async throws -> NinebotDashboard {
        if let cached = store.loadDashboard(), cached.primaryVehicle != nil {
            return cached
        }

        let dashboard = try await client.fetchDashboard(selectedSN: nil)
        let archivedDashboard = store.saveDashboard(dashboard)
        guard archivedDashboard.primaryVehicle != nil else {
            throw NinebotWidgetIntentError.missingVehicle
        }
        return archivedDashboard
    }

    private static func recordWidgetEvent(
        store: NinebotSharedStore,
        startedAt: Date,
        operation: String,
        success: Bool,
        message: String?
    ) {
        store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
            source: "Widget",
            operation: operation,
            startedAt: startedAt,
            endedAt: Date(),
            success: success,
            message: message
        ))
    }
}

private enum NinebotWidgetIntentError: LocalizedError {
    case missingConfiguration
    case missingVehicle

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "请先在 App 里配置数据源"
        case .missingVehicle:
            return "没有找到可操作的车辆"
        }
    }
}
