import Combine
import CoreLocation
import Foundation
import MapKit
import WidgetKit

enum NinebotInputError: LocalizedError {
    case missingProxy
    case missingAccount
    case missingPassword
    case missingCode
    case platformOnly

    var errorDescription: String? {
        switch self {
        case .missingProxy:
            return "请先填写服务地址"
        case .missingAccount:
            return "请填写 NinePlus 账号"
        case .missingPassword:
            return "请填写 NinePlus 密码"
        case .missingCode:
            return "请填写验证码"
        case .platformOnly:
            return "请切换到服务器模式后再拉取历史行程"
        }
    }
}

enum NinebotVehicleAction: String, CaseIterable, Identifiable {
    case bell
    case openBucket
    case engineStart
    case engineStop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bell: return "寻车铃"
        case .openBucket: return "开座桶"
        case .engineStart: return "上电"
        case .engineStop: return "熄火"
        }
    }

    var resultTitle: String {
        switch self {
        case .bell: return "寻车铃已发送"
        case .openBucket: return "开座桶指令已发送"
        case .engineStart: return "上电指令已发送"
        case .engineStop: return "熄火指令已发送"
        }
    }

    var loadingTitle: String {
        switch self {
        case .bell: return "正在寻车鸣笛"
        case .openBucket: return "正在打开座桶"
        case .engineStart: return "正在开锁"
        case .engineStop: return "正在关锁"
        }
    }

    var subtitle: String {
        switch self {
        case .bell: return "让车辆发出提示音"
        case .openBucket: return "打开座桶"
        case .engineStart: return "车辆进入可骑行状态"
        case .engineStop: return "关闭电源并锁车"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .bell: return "发送寻车铃？"
        case .openBucket: return "打开座桶？"
        case .engineStart: return "车辆上电？"
        case .engineStop: return "车辆熄火？"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .bell:
            return "车辆会发出提示音。"
        case .openBucket:
            return "座桶会被打开，请确认车辆在你身边。"
        case .engineStart:
            return "车辆会进入上电/解锁状态，请确认车辆在你身边。"
        case .engineStop:
            return "车辆会进入熄火/锁车状态，请确认不会影响当前骑行。"
        }
    }

    var systemImage: String {
        switch self {
        case .bell: return "bell.fill"
        case .openBucket: return "shippingbox.fill"
        case .engineStart: return "power.circle.fill"
        case .engineStop: return "lock.fill"
        }
    }

    var isDangerous: Bool {
        switch self {
        case .engineStart, .engineStop, .openBucket:
            return true
        case .bell:
            return false
        }
    }
}

struct NinebotDiagnosticsSnapshot {
    var hasConfiguration: Bool
    var proxyText: String
    var accountText: String
    var vehicleCount: Int
    var selectedVehicleName: String
    var dashboardUpdatedAt: Date?
    var lastAppRefreshEvent: NinebotRefreshEvent?
    var lastWidgetRefreshEvent: NinebotRefreshEvent?
    var lastError: String?
    var interfaceRideCount: Int
    var historyPointCount: Int
    var recordedRideCount: Int
    var rideDetailCount: Int
    var resolvedAddressCount: Int
    var dashboardCacheBytes: Int
}

@MainActor
final class NinebotViewModel: ObservableObject {
    @Published var dataSourceMode: NinebotDataSourceMode = .platform
    @Published var baseURLString = ""
    @Published var bearerToken = ""
    // Only NinePlus credentials are entered on this device. The portal
    // password is never persisted; the official cloud binding stays on the server.
    @Published var portalUsername = ""
    @Published var portalPassword = ""
    @Published var pushDeviceToken: String?
    @Published var portalLoginResult: NinePlusPortalLoginResult?
    @Published var dashboard: NinebotDashboard
    @Published var isLoading = false
    @Published private(set) var isRefreshingDashboard = false
    @Published private(set) var lastRefreshFailureAt: Date?
    @Published var loadingMessage: String?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var activeVehicleAction: NinebotVehicleAction?
    @Published private(set) var activeVehicleActionSN: String?
    @Published private(set) var latestVehicleActionMessage: String?
    @Published private(set) var isLatestVehicleActionError = false
    @Published private(set) var history: [String: [NinebotVehicleHistoryPoint]] = [:]
    @Published private(set) var resolvedAddresses: [String: NinebotResolvedAddress] = [:]
    @Published private(set) var recordedRides: [NinebotRecordedRide] = []
    @Published private(set) var rideDetails: [String: NinebotRideDetail] = [:]
    @Published private(set) var vehicleEvents: [NinebotVehicleEvent] = []
    @Published private(set) var loadingRideDetailKeys: Set<String> = []
    @Published private(set) var syncingTravelMonth: String?

    private let store = NinebotSharedStore()
    private var lastAutomaticRefreshAt: Date?
    private var isPerformingSilentDashboardRefresh = false
    private var foregroundRefreshTask: Task<Void, Never>?
    private var dashboardEnrichmentTask: Task<Void, Never>?
    private var pendingAutomaticRefresh = false

    private var automaticRefreshInterval: TimeInterval {
        // Keep charging feedback prompt while avoiding unnecessary requests when parked.
        dashboard.primaryVehicle?.state.isCharging == true ? 3 : 6
    }

    init() {
        let configuration = store.loadConfiguration()
        let portalLoginResult = store.loadPortalLoginResult()
        self.dataSourceMode = store.loadDataSourceMode()
        self.baseURLString = configuration?.baseURLString ?? NinebotAppRuntimeConfiguration.baseURL
        self.bearerToken = configuration?.bearerToken ?? ""
        self.portalLoginResult = portalLoginResult
        self.portalUsername = portalLoginResult?.username ?? ""
        // Old builds persisted a device-local official-account session. It is
        // no longer used for authorization, so remove it during migration.
        store.clearLoginResult()
        self.pushDeviceToken = store.loadPushDeviceToken()
        self.dashboard = store.loadDashboard() ?? .empty
        self.errorMessage = store.loadLastError()
        self.history = Self.historyMap(for: self.dashboard, store: store)
        self.resolvedAddresses = store.loadResolvedAddresses().filter { $0.value.source == Self.addressGeocodingSource }
        self.recordedRides = store.loadRecordedRides()
        self.vehicleEvents = store.loadVehicleEvents()
    }

    var hasConfiguration: Bool {
        currentConfiguration.isUsable
    }

    /// NinePlus is the only interactive login on a device. The official
    /// Ninebot cloud binding belongs to the server installation and is
    /// reported by the portal session, so a new device does not need the
    /// official account password; each device only needs the NinePlus session.
    var hasConnectionSession: Bool {
        hasConfiguration
            && activeSessionToken?.trimmed.isEmpty == false
    }

    var isConnectionInputComplete: Bool {
        hasConfiguration
    }

    var dataSourceStatusTitle: String {
        hasConfiguration ? "\(dataSourceMode.shortTitle)已配置" : "未配置\(dataSourceMode.shortTitle)"
    }

    var dataSourceStatusDetail: String {
        let value = baseURLString.trimmed
        if !value.isEmpty {
            return value
        }
        return dataSourceMode == .platform ? "填写 NinePlus Platform 地址后读取服务器归档数据" : "填写 ninecli serve 地址后直接读取代理"
    }

    var hasVehicles: Bool {
        !dashboard.vehicles.isEmpty
    }

    var currentAccountDisplay: String {
        if dashboard.vehicles.count == 1 {
            return dashboard.primaryVehicle?.vehicle.name ?? "已连接车辆"
        }
        if dashboard.vehicles.count > 1 {
            return "已连接 \(dashboard.vehicles.count) 辆车辆"
        }
        if let username = portalLoginResult?.username, !username.trimmed.isEmpty {
            return "NinePlus · \(username)"
        }
        return "NinePlus 用户"
    }

    // Compatibility names retained for widgets and older views.
    var isNinePlusAuthenticated: Bool { hasConfiguration }

    var hasOfficialNinebotAccount: Bool {
        // Compatibility name retained for widgets and older views. It now
        // reflects server readiness, never a device-local Ninebot session.
        portalLoginResult?.officialAccountBound == true
    }

    var hasLoginAccount: Bool { hasConnectionSession }

    var loginAccountCount: Int {
        dataSourceMode == .platform ? dashboard.vehicles.count : (hasOfficialNinebotAccount ? 1 : 0)
    }

    var isAddressGeocodingEnabled: Bool {
        true
    }

    func refreshOnLaunchIfPossible() async {
        // The dashboard cache is assigned during init. Do not block its first
        // live update on APNs registration or reverse geocoding.
        Task { [weak self] in
            guard let self else { return }
            await self.syncPushDeviceTokenIfPossible()
        }
        startForegroundRefreshLoop()
        // A launch must always request fresh vehicle data instead of being
        // suppressed by a timestamp from the previous foreground session.
        let refreshed = await refreshAutomaticallyIfPossible(force: true)
        if !refreshed, hasConnectionSession {
            // Do not leave a many-hours-old cached timestamp on screen after a
            // transient wake/network failure. The normal poll will recover too,
            // but this short retry makes cold starts deterministic.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = await refreshAutomaticallyIfPossible(force: true)
        }
    }

    /// Called by ContentView whenever scenePhase returns to `.active`.
    /// It reads the persisted dashboard immediately (during init) and then
    /// updates it in the background without replacing it with an empty state.
    func refreshWhenActiveIfPossible() async {
        Task { [weak self] in
            guard let self else { return }
            await self.syncPushDeviceTokenIfPossible()
        }
        startForegroundRefreshLoop()
        // Refresh immediately on every foreground entry. The in-flight guard
        // below coalesces the launch task and the active-scene callback.
        await refreshAutomaticallyIfPossible(force: true)
    }

    func stopForegroundRefreshLoop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    private func startForegroundRefreshLoop() {
        guard hasConnectionSession, foregroundRefreshTask == nil else { return }

        foregroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.automaticRefreshInterval

                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await self.refreshAutomaticallyIfPossible(force: false)
            }
        }
    }

    private func refreshAutomaticallyIfPossible(force: Bool) async -> Bool {
        guard hasConfiguration, activeSessionToken?.trimmed.isEmpty == false else { return false }

        // Launch and scene activation can arrive together. A request already
        // in flight is the fresh read we need, so never issue a duplicate.
        if isLoading {
            pendingAutomaticRefresh = true
            return false
        }
        guard !isPerformingSilentDashboardRefresh else { return false }

        let now = Date()
        if !force,
           let lastAutomaticRefreshAt,
           now.timeIntervalSince(lastAutomaticRefreshAt) < automaticRefreshInterval {
            return false
        }

        lastAutomaticRefreshAt = now
        return await refreshDashboardSilently()
    }

    private func refreshDashboardSilently() async -> Bool {
        guard !isPerformingSilentDashboardRefresh else { return false }
        lastRefreshFailureAt = nil
        isPerformingSilentDashboardRefresh = true
        isRefreshingDashboard = true
        defer {
            isPerformingSilentDashboardRefresh = false
            isRefreshingDashboard = false
        }

        do {
            let refreshedDashboard = try await fetchDashboardWithSessionRecovery(selectedSN: dashboard.selectedSN)
            let archivedDashboard = saveDashboard(refreshedDashboard)
            await cacheVehicleImages(for: archivedDashboard)
            await refreshResolvedAddressesIfNeeded(for: archivedDashboard)
            errorMessage = nil
            statusMessage = "已静默更新 \(Self.timeFormatter.string(from: archivedDashboard.updatedAt))"
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            // Keep cached vehicle data visible, but do not hide the failure:
            // otherwise the UI can look connected while showing a snapshot from
            // hours ago (for example phone 16:06, data 10:24).
            lastRefreshFailureAt = Date()
            let message = error.localizedDescription
            statusMessage = dashboard.vehicles.isEmpty
                ? nil
                : "自动刷新失败，显示缓存（更新于 \(Self.timeFormatter.string(from: dashboard.updatedAt))）"
            if dashboard.vehicles.isEmpty {
                errorMessage = message
                store.saveLastError(message)
            }
            return false
        }
    }

    func saveConfiguration() {
        let configuration = currentConfiguration
        guard !baseURLString.trimmed.isEmpty else {
            errorMessage = NinebotInputError.missingProxy.localizedDescription
            return
        }
        store.saveDataSourceMode(dataSourceMode)
        store.saveConfiguration(configuration)
        errorMessage = nil
        statusMessage = "\(dataSourceMode.shortTitle)配置已保存"
    }

    func saveDataSourceMode() {
        store.saveDataSourceMode(dataSourceMode)
        clearMessages()
        statusMessage = "已切换为\(dataSourceMode.title)"
    }

    func connectToService() async {
        await runLoadingOperation(message: "正在连接服务并获取车辆") {
            guard self.hasConfiguration else {
                throw NinebotProxyError.server("NinePlus 服务地址无效")
            }
            self.saveConfiguration()
            let client = try self.makeClient()
            let dashboard = try await self.fetchDashboardWithSessionRecovery(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            self.scheduleDashboardEnrichment(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = archivedDashboard.vehicles.isEmpty ? "服务已连接，但没有车辆数据" : "服务已连接，已获取车辆信息"
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func testConnection() async {
        await runLoadingOperation(message: "正在测试连接") {
            let client = try makeClient()
            let health = try await client.healthCheck()
            let bearerRequired = health.objectValue?["bearer_token_required"]?.boolValue == true
            let tokenState = bearerRequired
                ? (self.bearerToken.trimmed.isEmpty ? "，服务器要求 Bearer Token，请填写后再登录" : "，Bearer Token 已随请求发送")
                : "，服务器未开启 Bearer Token"
            self.errorMessage = nil
            self.statusMessage = "\(self.dataSourceMode.shortTitle)连接正常\(tokenState)"
        }
    }

    func refreshLoginToken() async {
        await runLoadingOperation(message: "正在刷新登录状态") {
            let client = try makeClient()
            if let refreshedToken = try await client.refreshNinePlusSession()?.trimmed,
               !refreshedToken.isEmpty {
                updateSessionToken(refreshedToken)
            }
            self.errorMessage = nil
            self.statusMessage = "登录状态已刷新"
        }
    }

    func refreshDashboard() async {
        await runLoadingOperation(message: "正在刷新车况") {
            let client = try makeClient()
            let dashboard = try await self.fetchDashboardWithSessionRecovery(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            self.scheduleDashboardEnrichment(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = "已更新 \(Self.timeFormatter.string(from: archivedDashboard.updatedAt))"
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func syncTravelMonth(vehicleSN: String, month: String) async {
        await runLoadingOperation(message: "正在获取 \(Self.displayMonth(month)) 行程") {
            guard self.dataSourceMode == .platform else {
                throw NinebotInputError.platformOnly
            }
            self.syncingTravelMonth = month
            defer { self.syncingTravelMonth = nil }

            let client = try makeClient()
            let page = try await client.syncTravelMonth(sn: vehicleSN, month: month, pageSize: 100)
            self.store.upsertInterfaceRideRecords(page.records, sn: vehicleSN)

            let dashboard = try await self.fetchDashboardWithSessionRecovery(selectedSN: vehicleSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            self.scheduleDashboardEnrichment(for: archivedDashboard)

            if page.total == 0 {
                self.statusMessage = "\(Self.displayMonth(month)) 暂无行程"
            } else {
                self.statusMessage = "已获取 \(Self.displayMonth(month)) \(page.total) 条行程"
            }
            self.errorMessage = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func resolveAddressesNow() async {
        await runLoadingOperation(message: "正在解析车辆位置") {
            try await self.resolveAddresses(for: self.dashboard, force: true)
            self.errorMessage = nil
            self.statusMessage = "车辆位置已解析"
        }
    }

    func enableChargingNotifications() async {
        await runLoadingOperation(message: "正在开启设备通知") {
            guard self.dataSourceMode == .platform, self.hasConfiguration else {
                throw NinebotPushError.missingServer
            }
            self.saveConfiguration()
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            self.pushDeviceToken = self.store.loadPushDeviceToken()
            if self.pushDeviceToken != nil {
                try await NinebotPushManager.shared.registerStoredTokenWithServer()
                self.statusMessage = "充电、骑行与报警通知已开启"
            } else {
                self.statusMessage = "已允许通知，系统返回 APNs Token 后会自动上报"
            }
            self.errorMessage = nil
        }
    }

    func syncPushDeviceToken() async {
        await runLoadingOperation(message: "正在重新上报 APNs 设备") {
            guard self.dataSourceMode == .platform, self.hasConfiguration else {
                throw NinebotPushError.missingServer
            }
            self.saveConfiguration()
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            self.pushDeviceToken = self.store.loadPushDeviceToken()
            try await NinebotPushManager.shared.registerStoredTokenWithServer()
            self.statusMessage = "APNs 设备 Token 已上报"
            self.errorMessage = nil
        }
    }

    func syncPushDeviceTokenIfPossible() async {
        guard dataSourceMode == .platform, hasConfiguration else { return }
        do {
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            pushDeviceToken = store.loadPushDeviceToken()
            if pushDeviceToken != nil {
                try await NinebotPushManager.shared.registerStoredTokenWithServer()
            }
        } catch {
            // Token sync should not block normal app refresh; diagnostics can surface manual retry errors.
        }
    }

    func loginToNinePlus() async {
        await runLoadingOperation(message: "正在登录 NinePlus") {
            guard !portalUsername.trimmed.isEmpty else { throw NinebotInputError.missingAccount }
            guard !portalPassword.isEmpty else { throw NinebotInputError.missingPassword }
            guard self.hasConfiguration else {
                throw NinebotProxyError.server("NinePlus 服务地址无效，请检查服务配置")
            }

            self.saveConfiguration()
            let client = try makeClient()
            let result = try await client.loginToNinePlus(username: portalUsername.trimmed, password: portalPassword)
            portalLoginResult = result
            store.savePortalLoginResult(result)
            portalPassword = ""
            startForegroundRefreshLoop()

            let dashboard = try await self.fetchDashboardWithSessionRecovery(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            self.scheduleDashboardEnrichment(for: archivedDashboard)
            store.saveConfiguration(currentConfiguration)
            errorMessage = nil
            statusMessage = archivedDashboard.vehicles.isEmpty ? "NinePlus 登录成功，但未找到车辆" : "NinePlus 登录成功，已获取车辆信息"
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func selectVehicle(sn: String) {
        dashboard.selectedSN = sn
        saveDashboard(dashboard)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func perform(_ action: NinebotVehicleAction, sn: String) async {
        activeVehicleAction = action
        activeVehicleActionSN = sn
        latestVehicleActionMessage = nil
        isLatestVehicleActionError = false
        errorMessage = nil
        defer {
            activeVehicleAction = nil
            activeVehicleActionSN = nil
        }

        await runLoadingOperation(message: action.loadingTitle) {
            let client = try makeClient()
            switch action {
            case .bell:
                _ = try await client.ringBell(sn: sn)
            case .openBucket:
                _ = try await client.openBucket(sn: sn)
            case .engineStart:
                _ = try await client.engineStart(sn: sn)
            case .engineStop:
                _ = try await client.engineStop(sn: sn)
            }

            // The command itself has succeeded at this point. A follow-up
            // refresh is best-effort so intermittent dashboard sync failures
            // never make an already-sent bucket/control command look failed.
            self.statusMessage = action.resultTitle
            self.latestVehicleActionMessage = action.resultTitle
            self.isLatestVehicleActionError = false
            self.errorMessage = nil

            do {
                let dashboard = try await self.fetchDashboardWithSessionRecovery(selectedSN: sn)
                let archivedDashboard = self.saveDashboard(dashboard)
                self.scheduleDashboardEnrichment(for: archivedDashboard)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                self.statusMessage = "\(action.resultTitle)，车辆状态将在下次同步时更新"
                self.latestVehicleActionMessage = self.statusMessage
                self.isLatestVehicleActionError = false
            }
        }

        if let errorMessage = self.errorMessage {
            self.latestVehicleActionMessage = errorMessage
            self.isLatestVehicleActionError = true
        }
    }

    func history(for sn: String) -> [NinebotVehicleHistoryPoint] {
        history[sn] ?? []
    }

    func recordedRides(for sn: String?) -> [NinebotRecordedRide] {
        recordedRides.filter { ride in
            guard let sn else { return true }
            return ride.vehicleSN == nil || ride.vehicleSN == sn
        }
    }

    func recordedRide(associatedWith rideID: String, vehicleSN: String?) -> NinebotRecordedRide? {
        recordedRides.first { ride in
            ride.associatedRideID == rideID && (vehicleSN == nil || ride.vehicleSN == nil || ride.vehicleSN == vehicleSN)
        }
    }

    func rideDetail(vehicleSN: String, rideID: String) -> NinebotRideDetail? {
        rideDetails[rideDetailKey(vehicleSN: vehicleSN, rideID: rideID)]
    }

    func isLoadingRideDetail(vehicleSN: String, rideID: String) -> Bool {
        loadingRideDetailKeys.contains(rideDetailKey(vehicleSN: vehicleSN, rideID: rideID))
    }

    func refreshRideDetail(vehicleSN: String, rideID: String, force: Bool = false) async {
        let key = rideDetailKey(vehicleSN: vehicleSN, rideID: rideID)
        guard force || rideDetails[key] == nil else { return }
        guard !loadingRideDetailKeys.contains(key) else { return }

        loadingRideDetailKeys.insert(key)
        defer {
            loadingRideDetailKeys.remove(key)
        }

        do {
            let client = try makeClient()
            let detail = try await client.fetchTravelDetail(sn: vehicleSN, travelID: rideID)
            rideDetails[key] = detail
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveRecordedRide(_ ride: NinebotRecordedRide) {
        store.upsertRecordedRide(ride)
        recordedRides = store.loadRecordedRides()
        statusMessage = "骑行记录已保存"
    }

    func deleteRecordedRide(id: String) {
        store.deleteRecordedRide(id: id)
        recordedRides = store.loadRecordedRides()
        statusMessage = "骑行记录已删除"
    }

    func resolvedAddressText(for snapshot: NinebotVehicleSnapshot) -> String? {
        return resolvedAddresses[snapshot.vehicle.sn]?.address
    }

    func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    /// Clears only the NinePlus portal session. The official cloud password is
    /// never persisted on this device, and the server session can disappear after a restart,
    /// so a stale token must return the UI to the first login step.
    func clearNinePlusSession() {
        portalLoginResult = nil
        portalUsername = ""
        portalPassword = ""
        store.clearPortalLoginResult()
        // Remove legacy device-local Ninebot login data while retaining only
        // the server address and non-secret configuration.
        store.clearLoginResult()
        store.saveConfiguration(currentConfiguration)
        errorMessage = nil
        statusMessage = "NinePlus 登录状态已失效，请重新登录 NinePlus 账号"
    }

    func diagnosticsSnapshot() -> NinebotDiagnosticsSnapshot {
        let vehicles = dashboard.vehicles
        let interfaceRideCount = vehicles.reduce(0) { count, snapshot in
            count + store.interfaceRideCount(sn: snapshot.vehicle.sn)
        }
        let historyPointCount = vehicles.reduce(0) { count, snapshot in
            count + store.historyCount(sn: snapshot.vehicle.sn)
        }

        return NinebotDiagnosticsSnapshot(
            hasConfiguration: hasConfiguration,
            proxyText: diagnosticsConnectionText,
            accountText: currentAccountDisplay,
            vehicleCount: vehicles.count,
            selectedVehicleName: dashboard.primaryVehicle?.vehicle.name ?? "暂无车辆",
            dashboardUpdatedAt: dashboard.updatedAt == .distantPast ? nil : dashboard.updatedAt,
            lastAppRefreshEvent: store.loadLastAppRefreshEvent(),
            lastWidgetRefreshEvent: store.loadLastWidgetRefreshEvent(),
            lastError: errorMessage ?? store.loadLastError(),
            interfaceRideCount: interfaceRideCount,
            historyPointCount: historyPointCount,
            recordedRideCount: store.recordedRideCount(),
            rideDetailCount: rideDetails.count,
            resolvedAddressCount: resolvedAddresses.count,
            dashboardCacheBytes: store.storedDashboardByteCount()
        )
    }

    private var activeSessionToken: String? {
        portalLoginResult?.sessionToken?.trimmed
    }

    private var currentConfiguration: NinebotProxyConfiguration {
        NinebotProxyConfiguration(
            baseURLString: baseURLString,
            bearerToken: bearerToken,
            appSessionToken: activeSessionToken
        )
    }

    private var diagnosticsConnectionText: String {
        baseURLString.trimmed.isEmpty ? "\(dataSourceMode.shortTitle)未配置" : "\(dataSourceMode.shortTitle) · \(baseURLString.trimmed)"
    }

    private func makeClient() throws -> NinebotProxyClient {
        let configuration = currentConfiguration
        guard configuration.isUsable else {
            throw NinebotInputError.missingProxy
        }
        store.saveDataSourceMode(dataSourceMode)
        store.saveConfiguration(configuration)
        return NinebotProxyClient(configuration: configuration)
    }

    /// Equivalent to an HTTP interceptor for URLSession: a failed vehicle
    /// request receives one refresh attempt and is replayed once. Credentials
    /// are never persisted, so only the server-issued session is renewed.
    private func fetchDashboardWithSessionRecovery(selectedSN: String?) async throws -> NinebotDashboard {
        let client = try makeClient()
        do {
            return try await client.fetchDashboard(selectedSN: selectedSN)
        } catch {
            guard Self.isUnauthorized(error) else { throw error }

            // The request client already performs a headerless fallback for a
            // restarted server. If that still gets 401, ask the backend to
            // refresh the user session once, save a returned replacement token,
            // then replay the original dashboard request exactly once.
            do {
                let refreshedToken = try await client.refreshNinePlusSession()
                if let refreshedToken = refreshedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !refreshedToken.isEmpty {
                    updateSessionToken(refreshedToken)
                }
                return try await makeClient().fetchDashboard(selectedSN: selectedSN)
            } catch {
                throw error
            }
        }
    }

    private func updateSessionToken(_ token: String) {
        guard var currentPortal = portalLoginResult else { return }
        currentPortal.sessionToken = token
        portalLoginResult = currentPortal
        store.savePortalLoginResult(currentPortal)
        store.saveConfiguration(currentConfiguration)
    }

    private func rideDetailKey(vehicleSN: String, rideID: String) -> String {
        "\(vehicleSN)|\(rideID)"
    }

    @discardableResult
    private func saveDashboard(_ dashboard: NinebotDashboard) -> NinebotDashboard {
        let previousDashboard = self.dashboard
        let archivedDashboard = store.saveDashboard(dashboard)
        recordVehicleEvents(previous: previousDashboard, current: archivedDashboard)
        self.dashboard = archivedDashboard
        history = Self.historyMap(for: archivedDashboard, store: store)
        NinebotChargingLiveActivityManager.sync(with: archivedDashboard)
        return archivedDashboard
    }

    private func recordVehicleEvents(previous: NinebotDashboard, current: NinebotDashboard) {
        var nextEvents = vehicleEvents
        let now = current.updatedAt

        for snapshot in current.vehicles {
            let old = previous.vehicles.first(where: { $0.vehicle.sn == snapshot.vehicle.sn })
            let oldCharging = old?.state.isCharging == true
            let newCharging = snapshot.state.isCharging == true

            if !oldCharging && newCharging {
                nextEvents.insert(NinebotVehicleEvent(
                    id: "charge-start-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .chargeStarted,
                    title: NinebotVehicleEventType.chargeStarted.title,
                    detail: "车辆检测到充电开始",
                    occurredAt: now,
                    latitude: snapshot.state.latitude,
                    longitude: snapshot.state.longitude,
                    durationMinutes: nil,
                    chargingPower: snapshot.state.chargingPower,
                    batteryTemperature: snapshot.state.batteryTemperature,
                    voltage: snapshot.state.batteryVoltage
                ), at: 0)
            } else if oldCharging && !newCharging {
                let matchingStart = nextEvents.first(where: { $0.vehicleSN == snapshot.vehicle.sn && $0.type == .chargeStarted })
                let duration = matchingStart.map { max(now.timeIntervalSince($0.occurredAt) / 60, 0) }
                nextEvents.insert(NinebotVehicleEvent(
                    id: "charge-end-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .chargeEnded,
                    title: NinebotVehicleEventType.chargeEnded.title,
                    detail: "车辆检测到充电结束",
                    occurredAt: now,
                    latitude: snapshot.state.latitude,
                    longitude: snapshot.state.longitude,
                    durationMinutes: duration,
                    chargingPower: snapshot.state.chargingPower,
                    batteryTemperature: snapshot.state.batteryTemperature,
                    voltage: snapshot.state.batteryVoltage
                ), at: 0)
            }

            let oldRiding = old?.state.isRiding == true
            let newRiding = snapshot.state.isRiding == true
            if !oldRiding && newRiding {
                nextEvents.insert(NinebotVehicleEvent(
                    id: "ride-start-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .rideStarted,
                    title: NinebotVehicleEventType.rideStarted.title,
                    detail: "接口检测到车辆开始骑行\(snapshot.state.currentSpeedKmh.map { "，当前 \(Int($0.rounded())) km/h" } ?? "")",
                    occurredAt: now,
                    latitude: snapshot.state.latitude,
                    longitude: snapshot.state.longitude,
                    durationMinutes: nil,
                    chargingPower: nil,
                    batteryTemperature: snapshot.state.batteryTemperature,
                    voltage: snapshot.state.batteryVoltage
                ), at: 0)
            } else if oldRiding && !newRiding, snapshot.state.isRiding == false {
                let matchingStart = nextEvents.first(where: { $0.vehicleSN == snapshot.vehicle.sn && $0.type == .rideStarted })
                let duration = matchingStart.map { max(now.timeIntervalSince($0.occurredAt) / 60, 0) }
                nextEvents.insert(NinebotVehicleEvent(
                    id: "ride-end-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .rideEnded,
                    title: NinebotVehicleEventType.rideEnded.title,
                    detail: "接口检测到车辆结束骑行",
                    occurredAt: now,
                    latitude: snapshot.state.latitude,
                    longitude: snapshot.state.longitude,
                    durationMinutes: duration,
                    chargingPower: nil,
                    batteryTemperature: snapshot.state.batteryTemperature,
                    voltage: snapshot.state.batteryVoltage
                ), at: 0)
            }

            // Only cloud warning/fault fields form alarm records. Lock state is
            // intentionally excluded: “currently unlocked” is not an alarm.
            if let alarm = alarmText(in: snapshot.state.rawStatus), alarm != alarmText(in: old?.state.rawStatus) {
                nextEvents.insert(NinebotVehicleEvent(
                    id: "alarm-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .alarm,
                    title: NinebotVehicleEventType.alarm.title,
                    detail: alarm,
                    occurredAt: now,
                    latitude: snapshot.state.latitude,
                    longitude: snapshot.state.longitude,
                    durationMinutes: nil,
                    chargingPower: nil,
                    batteryTemperature: snapshot.state.batteryTemperature,
                    voltage: snapshot.state.batteryVoltage
                ), at: 0)
            }
        }

        nextEvents = Array(nextEvents.sorted { $0.occurredAt > $1.occurredAt }.prefix(200))
        vehicleEvents = nextEvents
        store.saveVehicleEvents(nextEvents)
    }

    private func alarmText(in raw: [String: JSONValue]?) -> String? {
        guard let raw else { return nil }
        for (key, value) in raw {
            let normalizedKey = key.lowercased()
            guard normalizedKey.contains("alarm") || normalizedKey.contains("fault") || normalizedKey.contains("error") else { continue }
            if let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               !["0", "false", "no", "off", "none", "null"].contains(text.lowercased()) {
                return "\(key)：\(text)"
            }
            if let number = value.doubleValue, number != 0 {
                return "\(key)：\(number)"
            }
            if value.boolValue == true { return key }
        }
        return nil
    }

    private func refreshResolvedAddressesIfNeeded(for dashboard: NinebotDashboard) async {
        try? await resolveAddresses(for: dashboard, force: false)
    }

    /// Vehicle state is the only data needed to draw the dashboard. Reverse
    /// geocoding and remote image caching are best-effort enhancements, so run
    /// them concurrently after the new snapshot has already been persisted and
    /// published to SwiftUI.
    private func scheduleDashboardEnrichment(for dashboard: NinebotDashboard) {
        dashboardEnrichmentTask?.cancel()
        dashboardEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            async let imageCaching: Void = self.cacheVehicleImages(for: dashboard)
            async let addressResolution: Void = self.refreshResolvedAddressesIfNeeded(for: dashboard)
            _ = await (imageCaching, addressResolution)
        }
    }

    private func cacheVehicleImages(for dashboard: NinebotDashboard) async {
        for snapshot in dashboard.vehicles {
            guard let urlString = snapshot.vehicle.imageURLString?.trimmed,
                  !urlString.isEmpty,
                  let url = URL(string: urlString) else {
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      !data.isEmpty,
                      data.count <= 2_500_000 else {
                    continue
                }
                store.saveVehicleImageData(data, sn: snapshot.vehicle.sn)
            } catch {
                continue
            }
        }
    }

    private func resolveAddresses(for dashboard: NinebotDashboard, force: Bool) async throws {
        let geocoder = AppleReverseGeocoder()
        var nextAddresses = resolvedAddresses
        var didResolve = false
        var lastError: Error?
        var sawCoordinate = false

        for snapshot in dashboard.vehicles {
            guard let latitude = snapshot.state.latitude,
                  let longitude = snapshot.state.longitude else {
                continue
            }

            sawCoordinate = true
            if !force, let cached = nextAddresses[snapshot.vehicle.sn],
               isFreshAddress(cached, latitude: latitude, longitude: longitude) {
                continue
            }

            do {
                let geocodeCoordinate = NinebotCoordinateTransform.gcj02Coordinate(latitude: latitude, longitude: longitude)
                let address = try await geocoder.reverseGeocode(
                    latitude: geocodeCoordinate.latitude,
                    longitude: geocodeCoordinate.longitude
                )
                nextAddresses[snapshot.vehicle.sn] = NinebotResolvedAddress(
                    sn: snapshot.vehicle.sn,
                    address: address,
                    latitude: latitude,
                    longitude: longitude,
                    updatedAt: Date(),
                    source: Self.addressGeocodingSource
                )
                didResolve = true
            } catch {
                lastError = error
            }
        }

        resolvedAddresses = nextAddresses
        store.saveResolvedAddresses(nextAddresses)

        if force, !didResolve {
            if let lastError {
                throw lastError
            }
            if !sawCoordinate {
                throw AppleGeocodingError.missingCoordinate
            }
        }
    }

    private func isFreshAddress(
        _ address: NinebotResolvedAddress,
        latitude: Double,
        longitude: Double
    ) -> Bool {
        let sameCoordinate = abs(address.latitude - latitude) < 0.00001
            && abs(address.longitude - longitude) < 0.00001
        return sameCoordinate && Date().timeIntervalSince(address.updatedAt) < 15 * 60
    }


    private func runLoadingOperation(message: String, _ operation: () async throws -> Void) async {
        let startedAt = Date()
        loadingMessage = message
        isLoading = true

        do {
            try await operation()
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: "App",
                operation: message,
                startedAt: startedAt,
                endedAt: Date(),
                success: true,
                message: statusMessage
            ))
        } catch {
            let message = error.localizedDescription
            if Self.requiresInteractiveLogin(error) {
                clearNinePlusSession()
            }
            errorMessage = message
            statusMessage = nil
            store.saveLastError(message)
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: "App",
                operation: self.loadingMessage ?? "操作",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: message
            ))
        }

        isLoading = false
        loadingMessage = nil

        if pendingAutomaticRefresh {
            pendingAutomaticRefresh = false
            Task { [weak self] in
                guard let self else { return }
                _ = await self.refreshAutomaticallyIfPossible(force: true)
            }
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard let proxyError = error as? NinebotProxyError else { return false }
        if case .httpStatus(let statusCode, _) = proxyError {
            return statusCode == 401
        }
        return false
    }

    /// Do not erase the local dashboard for a bare 401: it can be a server
    /// restart or an expired short-lived access token. Only a clear server
    /// instruction to sign in again may return the user to the login screen.
    private static func requiresInteractiveLogin(_ error: Error) -> Bool {
        guard let proxyError = error as? NinebotProxyError else { return false }
        let message: String
        switch proxyError {
        case .httpStatus(_, let value), .server(let value):
            message = value
        default:
            return false
        }
        return message.contains("请重新登录")
            || message.contains("账号已注销")
            || message.contains("账户不存在")
    }

    private static func displayMonth(_ month: String) -> String {
        guard month.count == 6 else { return month }
        let year = month.prefix(4)
        let monthValue = month.suffix(2)
        return "\(year)年\(monthValue)月"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let addressGeocodingSource = "apple-mapkit"

    private static func historyMap(
        for dashboard: NinebotDashboard,
        store: NinebotSharedStore
    ) -> [String: [NinebotVehicleHistoryPoint]] {
        Dictionary(uniqueKeysWithValues: dashboard.vehicles.map { snapshot in
            (snapshot.vehicle.sn, store.loadHistory(sn: snapshot.vehicle.sn))
        })
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AppleGeocodingError: LocalizedError {
    case invalidResponse
    case missingCoordinate

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Apple 地址解析返回无效"
        case .missingCoordinate:
            return "车辆暂未返回可解析的坐标"
        }
    }
}

private struct AppleReverseGeocoder {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> String {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "zh_CN")
        )
        let address = Self.addressText(from: placemarks.first)
        guard !address.isEmpty else {
            throw AppleGeocodingError.invalidResponse
        }
        return address
    }

    private static func addressText(from placemark: CLPlacemark?) -> String {
        guard let placemark else { return "" }
        let components = [
            placemark.country,
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.subThoroughfare,
            placemark.name,
        ]
        var seen = Set<String>()
        return components.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return seen.insert(value).inserted ? value : nil
        }.joined()
    }
}
