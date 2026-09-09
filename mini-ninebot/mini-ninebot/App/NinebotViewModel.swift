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
    /// Month syncs are keyed by vehicle and month. A single optional month
    /// used to make selecting 2026.07 while another month was loading silently
    /// drop the new request, leaving the filter stuck on an empty month.
    @Published private(set) var syncingTravelMonthKeys: Set<String> = []
    @Published private(set) var travelMonthSyncErrors: [String: String] = [:]

    private let store = NinebotSharedStore()
    private var lastAutomaticRefreshAt: Date?
    private var isPerformingSilentDashboardRefresh = false
    private var foregroundRefreshTask: Task<Void, Never>?
    private var dashboardEnrichmentTask: Task<Void, Never>?
    private var dashboardTravelEnrichmentTask: Task<Void, Never>?
    // Extra pages are deliberately fetched after page one has rendered. Keep
    // one continuation per vehicle/month so quick re-selections cannot start
    // duplicate cloud reads.
    private var prefetchingTravelMonthKeys: Set<String> = []
    private var pendingAutomaticRefresh = false
    private var lastForegroundRefreshRequestAt: Date?
    private var lastBackgroundAt: Date?
    private var lastManualRefreshAt: Date?
    // Accessing UserDefaults and decoding up to hundreds of raw cloud trips on
    // every SwiftUI body evaluation caused a visible hitch when opening the
    // Records tab. Keep the already-loaded archive in memory; the durable
    // store remains the fallback after a cold migration.
    private var travelRecordCache: [String: [NinebotRideRecord]] = [:]

    private var automaticRefreshInterval: TimeInterval {
        // The dashboard endpoint is backed by a live Ninebot poll. Polling every
        // few seconds can queue overlapping origin work and make a completed
        // refresh look stale. Ten seconds is still responsive while charging;
        // parked vehicles do not need a tight loop.
        dashboard.primaryVehicle?.state.isCharging == true ? 10 : 30
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
        self.travelRecordCache = Self.travelRecordCache(for: self.dashboard)
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
        guard beginForegroundRefreshCycle() else { return }

        // The dashboard cache is assigned during init. Do not block its first
        // live update on APNs registration or reverse geocoding.
        Task { [weak self] in
            guard let self else { return }
            await self.syncPushDeviceTokenIfPossible()
        }
        startForegroundRefreshLoop()
        // Paint the persisted dashboard first. When the server already has a
        // snapshot this returns in milliseconds and schedules a background
        // refresh; a forced cold read is only needed when there is no local
        // vehicle data at all. This prevents launch from waiting on every
        // telemetry endpoint before the home screen becomes usable.
        let hasCachedDashboard = !dashboard.vehicles.isEmpty
        let refreshed = await refreshAutomaticallyIfPossible(force: !hasCachedDashboard)
        if hasCachedDashboard {
            // The stale snapshot path starts a server-side refresh. Re-read it
            // shortly after so real live status/battery values land within the
            // normal 3–5 second launch window without blocking first paint.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            _ = await refreshAutomaticallyIfPossible(force: true)
        } else if !refreshed, hasConnectionSession {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = await refreshAutomaticallyIfPossible(force: true)
        }
    }

    /// Called by ContentView whenever scenePhase returns to `.active`.
    /// It reads the persisted dashboard immediately (during init) and then
    /// updates it in the background without replacing it with an empty state.
    func refreshWhenActiveIfPossible() async {
        // scenePhase and UIApplication.didBecomeActive can both arrive during
        // one activation. Treat them as a single cycle, but never suppress a
        // later return from the background.
        guard beginForegroundRefreshCycle() else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.syncPushDeviceTokenIfPossible()
        }
        startForegroundRefreshLoop()
        await refreshAutomaticallyIfPossible(force: true)
    }

    private func beginForegroundRefreshCycle() -> Bool {
        let now = Date()
        if let lastForegroundRefreshRequestAt, lastBackgroundAt == nil,
           now.timeIntervalSince(lastForegroundRefreshRequestAt) < 1.5 {
            return false
        }
        lastForegroundRefreshRequestAt = now
        lastBackgroundAt = nil
        return true
    }

    func stopForegroundRefreshLoop() {
        lastBackgroundAt = Date()
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
        if isRefreshingDashboard {
            // A manual pull/button refresh is already the authoritative live
            // read. Do not schedule another automatic request behind it.
            return false
        }
        if isLoading {
            pendingAutomaticRefresh = true
            return false
        }
        // A foreground activation can arrive while a previous silent request
        // is winding down. Queue one forced read after it finishes so a stale
        // response that completed while the app was backgrounded cannot win.
        if isPerformingSilentDashboardRefresh {
            if force {
                pendingAutomaticRefresh = true
            }
            return false
        }

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
            schedulePendingAutomaticRefreshIfNeeded()
        }

        do {
            // `fresh=1` is required by the NinePlus aggregate endpoint. A
            // non-fresh response can legitimately be an older server snapshot,
            // which was the main reason the spinner finished without visible
            // changes on the home screen.
            let refreshedDashboard = try await fetchDashboardWithSessionRecovery(
                selectedSN: dashboard.selectedSN,
                forceRefresh: true
            )
            let archivedDashboard = saveDashboard(refreshedDashboard)
            // Do not make the launch/foreground refresh wait for reverse
            // geocoding, remote images, or the optional travel/BMS reads.
            // Those operations previously kept `isRefreshingDashboard` true
            // for several seconds (or up to their request timeout), which made
            // the dashboard look slow even though a live vehicle snapshot had
            // already arrived. Start them after publishing the snapshot.
            scheduleDashboardEnrichment(for: archivedDashboard)
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
        // Pull-to-refresh, the header button, onAppear, and scene activation can
        // arrive together. Never start a second live read while the automatic
        // read is still in flight; the in-flight result is the newest snapshot.
        if isPerformingSilentDashboardRefresh {
            pendingAutomaticRefresh = false
            while isPerformingSilentDashboardRefresh && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }

        let now = Date()
        if let lastManualRefreshAt,
           now.timeIntervalSince(lastManualRefreshAt) < 4 {
            return
        }
        guard !isLoading else { return }
        lastManualRefreshAt = now
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        await runLoadingOperation(message: "正在刷新车况") {
            let dashboard = try await self.fetchDashboardWithSessionRecovery(
                selectedSN: self.dashboard.selectedSN,
                forceRefresh: true
            )
            let archivedDashboard = self.saveDashboard(dashboard)
            self.scheduleDashboardEnrichment(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = "已更新 \(Self.timeFormatter.string(from: archivedDashboard.updatedAt))"
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Quickly loads the first real cloud page for a calendar month. Remaining
    /// pages continue only after the first records are saved and rendered, so
    /// historical month selection never waits for a complete archive.
    ///
    /// This is intentionally not wrapped in `runLoadingOperation`: selecting
    /// Records is a background page-level read, not a blocking app operation.
    /// Toggling the global `isLoading` flag here invalidates the whole dashboard
    /// while the tab is opening and was the remaining source of the visible hitch.
    func syncTravelMonth(vehicleSN: String, month: String) async {
        guard beginTravelMonthSync(vehicleSN: vehicleSN, month: month) else { return }
        await performTravelMonthSync(vehicleSN: vehicleSN, month: month)
    }

    /// Starts a month request that is independent from the lifetime of the
    /// SwiftUI Records view. `.task` is allowed to cancel during navigation;
    /// the cloud request must not be cancelled with it after it has started.
    func startTravelMonthSyncIfNeeded(vehicleSN: String, month: String) {
        let key = Self.travelMonthSyncKey(vehicleSN: vehicleSN, month: month)
        guard dataSourceMode == .platform,
              shouldSyncTravelMonth(vehicleSN: vehicleSN, month: month) else {
            if dataSourceMode != .platform {
                travelMonthSyncErrors[key] = NinebotInputError.platformOnly.localizedDescription
            }
            return
        }

        guard beginTravelMonthSync(vehicleSN: vehicleSN, month: month) else { return }
        Task { [weak self] in
            await self?.performTravelMonthSync(vehicleSN: vehicleSN, month: month)
        }
    }

    private func beginTravelMonthSync(vehicleSN: String, month: String) -> Bool {
        let key = Self.travelMonthSyncKey(vehicleSN: vehicleSN, month: month)
        guard !syncingTravelMonthKeys.contains(key) else { return false }
        guard dataSourceMode == .platform else {
            travelMonthSyncErrors[key] = NinebotInputError.platformOnly.localizedDescription
            return false
        }
        syncingTravelMonthSyncState(key: key, month: month, isActive: true)
        travelMonthSyncErrors.removeValue(forKey: key)
        return true
    }

    private func syncingTravelMonthSyncState(key: String, month: String, isActive: Bool) {
        if isActive {
            syncingTravelMonthKeys.insert(key)
            syncingTravelMonth = month
        } else {
            syncingTravelMonthKeys.remove(key)
            syncingTravelMonth = syncingTravelMonthKeys.first.flatMap {
                $0.split(separator: "|").last.map(String.init)
            }
        }
    }

    private func performTravelMonthSync(vehicleSN: String, month: String) async {
        let key = Self.travelMonthSyncKey(vehicleSN: vehicleSN, month: month)
        defer {
            syncingTravelMonthSyncState(key: key, month: month, isActive: false)
        }

        do {
            let client = try makeClient()
            // `/travel` performs one ninecli request. The former
            // `/travel-sync` first assembled up to 99 pages serially,
            // keeping the view in a loading state for minutes.
            let firstPage = try await client.fetchTravelMonth(sn: vehicleSN, month: month)
            travelRecordCache[vehicleSN] = store.upsertInterfaceRideRecords(
                firstPage.records,
                sn: vehicleSN
            )
            travelMonthSyncErrors.removeValue(forKey: key)

            // Update the published archive directly. Do not trigger a
            // second dashboard request: that endpoint intentionally omits
            // old rides and could otherwise overwrite this visible month.
            let archivedDashboard = applyingArchivedTravelRecords(for: vehicleSN)
            if let archivedDashboard {
                scheduleDashboardEnrichment(for: archivedDashboard)
            }

            if firstPage.hasMore {
                prefetchRemainingTravelPages(
                    vehicleSN: vehicleSN,
                    month: month,
                    firstPage: firstPage
                )
            } else if firstPage.records.isEmpty && firstPage.sourceRecordCount > 0 {
                // Do not leave the UI in the ambiguous “准备获取” state when
                // the cloud returned rows that the normalizer could not map to
                // real trip start times. Surface the diagnostics and allow a
                // retry after the server parser is updated.
                let excluded = firstPage.excludedWithoutStartTime
                travelMonthSyncErrors[key] = excluded > 0
                    ? "服务器返回了 \(firstPage.sourceRecordCount) 条行程，但 \(excluded) 条缺少真实开始时间，未伪造日期。请重试或更新服务器。"
                    : "服务器返回了行程，但没有可显示的真实记录。请重试。"
                statusMessage = "\(Self.displayMonth(month)) 行程时间字段无法识别，未显示虚假数据"
            } else {
                // Only an explicit zero-row response is a trustworthy empty
                // month and may be cached as complete.
                store.markTravelMonthSynced(sn: vehicleSN, month: month)
            }

            let visibleCount = firstPage.records.count
            let knownTotal = max(firstPage.total, visibleCount)
            if visibleCount == 0 {
                statusMessage = "\(Self.displayMonth(month)) 暂无行程"
            } else if firstPage.hasMore && knownTotal > visibleCount {
                statusMessage = "已显示 \(Self.displayMonth(month)) \(visibleCount) 条行程，正在后台补齐其余 \(knownTotal - visibleCount) 条"
            } else {
                statusMessage = "已获取 \(Self.displayMonth(month)) \(visibleCount) 条行程"
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch is CancellationError {
            // The view task may cancel, but the view-model-owned task should
            // normally survive. Keep a visible retry state if a caller did
            // cancel a manually started request.
            travelMonthSyncErrors[key] = "获取请求被取消，请点击重新获取。"
        } catch {
            // Keep any previously cached real records visible. Only the
            // month-local error is published so the app-wide banner/loading
            // state cannot interrupt the Records tab transition.
            travelMonthSyncErrors[key] = error.localizedDescription
        }
    }

    /// Fetch additional upstream pages only after page one is visible. This is
    /// bounded by the server's upstream limit and stops immediately when a
    /// cloud version ignores the page parameter and repeats a page.
    private func prefetchRemainingTravelPages(
        vehicleSN: String,
        month: String,
        firstPage: NinebotTravelPage
    ) {
        let key = Self.travelMonthSyncKey(vehicleSN: vehicleSN, month: month)
        guard firstPage.hasMore, !prefetchingTravelMonthKeys.contains(key) else { return }
        prefetchingTravelMonthKeys.insert(key)

        Task { [weak self] in
            guard let self else { return }
            defer { self.prefetchingTravelMonthKeys.remove(key) }

            do {
                let client = try self.makeClient()
                var currentPage = firstPage
                var nextPageNumber = max(firstPage.page + 1, 2)
                var seenRideIDs = Set(firstPage.records.map(\.id))

                while currentPage.hasMore,
                      nextPageNumber <= 99,
                      !Task.isCancelled {
                    let nextPage = try await client.fetchTravelMonth(
                        sn: vehicleSN,
                        month: month,
                        page: nextPageNumber
                    )
                    guard !nextPage.records.isEmpty else { break }

                    let pageRideIDs = Set(nextPage.records.map(\.id))
                    // A few upstream versions silently return page one for
                    // every page number. Never burn through 99 requests or
                    // duplicate records in that case.
                    guard !pageRideIDs.isSubset(of: seenRideIDs) else { break }
                    seenRideIDs.formUnion(pageRideIDs)

                    self.travelRecordCache[vehicleSN] = self.store.upsertInterfaceRideRecords(
                        nextPage.records,
                        sn: vehicleSN
                    )
                    _ = self.applyingArchivedTravelRecords(for: vehicleSN)
                    currentPage = nextPage
                    nextPageNumber += 1
                }

                // Either all known pages were received, the upstream ended,
                // or it repeated a page. In every successful case the local
                // archive is now as complete as that cloud response allows.
                self.store.markTravelMonthSynced(sn: vehicleSN, month: month)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                // Page one remains valid and visible. Leave the month unmarked
                // so a later selection can resume the incomplete background
                // fetch instead of replacing real records with an error state.
            }
        }
    }

    /// Used by the month picker so a historical month is requested once when it
    /// is first selected, while successful empty months do not trigger a loop.
    func syncTravelMonthIfNeeded(vehicleSN: String, month: String) async {
        guard !Task.isCancelled else { return }
        // Launch from the view model so SwiftUI cancelling `.task(id:)` during
        // a tab transition cannot cancel the actual month request.
        startTravelMonthSyncIfNeeded(vehicleSN: vehicleSN, month: month)
    }

    func isSyncingTravelMonth(vehicleSN: String, month: String) -> Bool {
        syncingTravelMonthKeys.contains(Self.travelMonthSyncKey(vehicleSN: vehicleSN, month: month))
    }

    func hasSyncedTravelMonth(vehicleSN: String, month: String) -> Bool {
        store.travelMonthLastSyncedAt(sn: vehicleSN, month: month) != nil
    }

    func travelMonthSyncError(vehicleSN: String, month: String) -> String? {
        travelMonthSyncErrors[Self.travelMonthSyncKey(vehicleSN: vehicleSN, month: month)]
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

    /// Returns the durable travel archive without decoding it repeatedly on the
    /// main actor. The Records view calls this while SwiftUI is laying out the
    /// tab, so a memory cache prevents a UserDefaults/JSON decode hitch on every
    /// body update. The persisted archive is loaded only once as a migration
    /// fallback when a legacy dashboard has no embedded records.
    func travelRecords(for vehicleSN: String, month: String? = nil) -> [NinebotRideRecord] {
        let records: [NinebotRideRecord]
        if let cached = travelRecordCache[vehicleSN] {
            records = cached
        } else {
            let persisted = store.interfaceRideRecords(sn: vehicleSN)
            travelRecordCache[vehicleSN] = persisted
            records = persisted
        }

        guard let month else { return records }
        return records.filter { record in
            guard let date = record.startedAt ?? record.endedAt else { return false }
            return Self.travelMonthKey(for: date) == month
        }
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
    private func fetchDashboardWithSessionRecovery(
        selectedSN: String?,
        forceRefresh: Bool = true
    ) async throws -> NinebotDashboard {
        let client = try makeClient()
        do {
            return try await client.fetchDashboard(selectedSN: selectedSN, forceRefresh: forceRefresh)
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
                return try await makeClient().fetchDashboard(selectedSN: selectedSN, forceRefresh: forceRefresh)
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

    private func shouldSyncTravelMonth(vehicleSN: String, month: String) -> Bool {
        guard let lastSyncedAt = store.travelMonthLastSyncedAt(sn: vehicleSN, month: month) else {
            return true
        }

        // The current month remains live; older months are immutable in normal
        // use and only need an occasional server recheck. Manual "获取" actions
        // still call syncTravelMonth directly and bypass this interval.
        let isCurrentMonth = month == Self.travelMonthKey(for: Date())
        let refreshInterval: TimeInterval = isCurrentMonth ? 10 * 60 : 24 * 60 * 60
        return Date().timeIntervalSince(lastSyncedAt) >= refreshInterval
    }

    private func applyingArchivedTravelRecords(for vehicleSN: String) -> NinebotDashboard? {
        guard let vehicleIndex = dashboard.vehicles.firstIndex(where: { $0.vehicle.sn == vehicleSN }) else {
            return nil
        }

        var dashboardWithArchive = dashboard
        let records = travelRecordCache[vehicleSN] ?? store.interfaceRideRecords(sn: vehicleSN)
        travelRecordCache[vehicleSN] = records
        dashboardWithArchive.vehicles[vehicleIndex].state.rideRecords = records.isEmpty ? nil : records
        return saveDashboard(dashboardWithArchive)
    }

    private static func travelMonthSyncKey(vehicleSN: String, month: String) -> String {
        "\(vehicleSN)|\(month)"
    }

    private static func travelRecordCache(for dashboard: NinebotDashboard) -> [String: [NinebotRideRecord]] {
        Dictionary(uniqueKeysWithValues: dashboard.vehicles.compactMap { snapshot in
            let records = snapshot.state.rideRecords ?? []
            return records.isEmpty ? nil : (snapshot.vehicle.sn, records)
        })
    }

    @discardableResult
    private func saveDashboard(_ dashboard: NinebotDashboard) -> NinebotDashboard {
        let previousDashboard = self.dashboard
        let archivedDashboard = store.saveDashboard(dashboard)
        recordVehicleEvents(previous: previousDashboard, current: archivedDashboard)
        archiveCompletedChargingSessions(previous: previousDashboard, current: archivedDashboard)
        self.dashboard = archivedDashboard
        // Keep Records-tab reads in memory after every dashboard publication.
        // Values are arrays with copy-on-write storage, so this does not copy
        // raw trip JSON until a later mutation actually needs it.
        for (sn, records) in Self.travelRecordCache(for: archivedDashboard) where !records.isEmpty {
            travelRecordCache[sn] = records
        }
        history = Self.historyMap(for: archivedDashboard, store: store)
        NinebotChargingLiveActivityManager.sync(with: archivedDashboard)
        return archivedDashboard
    }

    private func archiveCompletedChargingSessions(previous: NinebotDashboard, current: NinebotDashboard) {
        for snapshot in current.vehicles {
            guard previous.vehicles.first(where: { $0.vehicle.sn == snapshot.vehicle.sn })?.state.isCharging == true,
                  snapshot.state.isCharging != true else { continue }

            let cached = store.loadHistory(sn: snapshot.vehicle.sn).sorted { $0.date < $1.date }
            guard let endIndex = cached.lastIndex(where: { point in
                point.date <= snapshot.state.updatedAt &&
                    (point.isCharging == true || (point.chargingPower ?? 0) > 0)
            }) else { continue }

            var startIndex = endIndex
            while startIndex > 0 {
                let current = cached[startIndex]
                let previous = cached[startIndex - 1]
                guard current.date.timeIntervalSince(previous.date) <= 20 * 60 else { break }
                let previousActive = previous.isCharging == true || (previous.chargingPower ?? 0) > 0
                if previousActive {
                    startIndex -= 1
                } else {
                    break
                }
            }

            var end = endIndex
            if end + 1 < cached.count,
               cached[end + 1].date.timeIntervalSince(cached[end].date) <= 20 * 60 {
                end += 1 // keep the first zero-power endpoint after unplugging
            }
            let sessionPoints = cached[startIndex...end].compactMap { point -> ChargingPowerPoint? in
                guard let power = point.chargingPower, power.isFinite, power >= 0 else { return nil }
                return ChargingPowerPoint(id: point.id, timestamp: point.date, power: power,
                                          voltage: point.batteryVoltage, current: point.batteryCurrent,
                                          temperature: point.batteryTemperature, soc: point.battery.map(Double.init))
            }
            guard let first = sessionPoints.first, let last = sessionPoints.last, sessionPoints.count >= 2 else { continue }
            store.upsertChargingSession(ChargingSession(
                id: "\(snapshot.vehicle.sn)-\(Int(first.timestamp.timeIntervalSince1970))",
                vehicleSN: snapshot.vehicle.sn,
                startedAt: first.timestamp,
                endedAt: last.timestamp,
                points: sessionPoints
            ))
        }
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

            let oldRiding = old?.state.isRideActive == true
            let newRiding = snapshot.state.isRideActive
            if !oldRiding && newRiding {
                nextEvents.insert(NinebotVehicleEvent(
                    id: "ride-start-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .rideStarted,
                    title: NinebotVehicleEventType.rideStarted.title,
                    detail: "车辆已开始骑行\(snapshot.state.currentSpeedKmh.map { "，当前 \(Int($0.rounded())) km/h" } ?? "")",
                    occurredAt: now,
                    latitude: snapshot.state.latitude,
                    longitude: snapshot.state.longitude,
                    durationMinutes: nil,
                    chargingPower: nil,
                    batteryTemperature: snapshot.state.batteryTemperature,
                    voltage: snapshot.state.batteryVoltage
                ), at: 0)
            } else if oldRiding && !newRiding {
                let matchingStart = nextEvents.first(where: { $0.vehicleSN == snapshot.vehicle.sn && $0.type == .rideStarted })
                let duration = matchingStart.map { max(now.timeIntervalSince($0.occurredAt) / 60, 0) }
                nextEvents.insert(NinebotVehicleEvent(
                    id: "ride-end-\(snapshot.vehicle.sn)-\(Int(now.timeIntervalSince1970))",
                    vehicleSN: snapshot.vehicle.sn,
                    vehicleName: snapshot.vehicle.name,
                    type: .rideEnded,
                    title: NinebotVehicleEventType.rideEnded.title,
                    detail: "车辆已结束骑行",
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
        // The optimized server dashboard deliberately omits travel history and
        // heavyweight BMS diagnostics so the home screen can render quickly.
        // Do not cancel this task on every 3-second charging refresh: doing so
        // starves the hydration request and leaves the cards at “--”.
        // The task merges into the latest dashboard when it completes.
        if dashboardTravelEnrichmentTask == nil {
            dashboardTravelEnrichmentTask = Task { [weak self] in
                guard let self else { return }
                await self.enrichCurrentMonthTravel(for: dashboard)
                if !Task.isCancelled {
                    self.dashboardTravelEnrichmentTask = nil
                }
            }
        }
    }

    private func enrichCurrentMonthTravel(for dashboard: NinebotDashboard) async {
        guard dataSourceMode == .platform, !dashboard.vehicles.isEmpty else { return }
        guard let client = try? makeClient() else { return }
        let month = NinebotProxyClient.currentMonthString()

        // The selected vehicle is the one visible on the home screen. Hydrate
        // it first so its battery card and "今日里程" have the shortest path,
        // then continue with any additional bound vehicles.
        let snapshots = dashboard.vehicles.sorted { lhs, rhs in
            let selectedSN = dashboard.selectedSN ?? self.dashboard.selectedSN
            if lhs.vehicle.sn == selectedSN { return true }
            if rhs.vehicle.sn == selectedSN { return false }
            return lhs.vehicle.sn < rhs.vehicle.sn
        }

        // Start every vehicle's travel and BMS reads together. The selected
        // vehicle is sorted first, so its result is applied first while the
        // remaining vehicles continue in parallel instead of blocking the
        // home screen one ninecli request at a time.
        let requests = snapshots.map { snapshot in
            Task { () -> (String, NinebotTravelPage?, JSONValue?) in
                async let pageResult = try? await client.fetchTravelMonth(
                    sn: snapshot.vehicle.sn,
                    month: month
                )
                async let batteryResult = try? await client.fetchBattery(sn: snapshot.vehicle.sn)
                return (snapshot.vehicle.sn, await pageResult, await batteryResult)
            }
        }

        // Re-read `self.dashboard` for every result: an automatic status
        // refresh can finish while these requests are in flight, and saving a
        // snapshot captured before the await would otherwise overwrite newer
        // telemetry.
        for request in requests {
            guard !Task.isCancelled else { return }
            let (vehicleSN, page, battery) = await request.value
            guard !Task.isCancelled, page != nil || battery != nil else { continue }

            var dashboardToUpdate = self.dashboard
            guard let index = dashboardToUpdate.vehicles.firstIndex(where: { $0.vehicle.sn == vehicleSN }) else {
                continue
            }

            let current = dashboardToUpdate.vehicles[index]
            if let page, !page.records.isEmpty {
                travelRecordCache[vehicleSN] = store.upsertInterfaceRideRecords(
                    page.records,
                    sn: vehicleSN
                )
            }

            let state = NinebotProxyClient.vehicleState(
                status: current.state.rawStatus.map(JSONValue.object),
                travel: page?.raw ?? current.state.rawTravel.map(JSONValue.object),
                battery: battery ?? current.state.rawBattery.map(JSONValue.object),
                updatedAt: current.state.updatedAt
            )
            var mergedState = state
            mergedState.serverPrediction = current.state.serverPrediction
            mergedState.totalMileage = state.totalMileage ?? current.state.totalMileage
            mergedState.lastMileage = state.lastMileage ?? current.state.lastMileage
            dashboardToUpdate.vehicles[index].state = mergedState
            _ = saveDashboard(dashboardToUpdate)
            WidgetCenter.shared.reloadAllTimelines()
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

        schedulePendingAutomaticRefreshIfNeeded()
    }

    private func schedulePendingAutomaticRefreshIfNeeded() {
        guard pendingAutomaticRefresh else { return }
        pendingAutomaticRefresh = false
        Task { [weak self] in
            guard let self else { return }
            _ = await self.refreshAutomaticallyIfPossible(force: true)
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

    private static let travelMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyyMM"
        return formatter
    }()

    private static func travelMonthKey(for date: Date) -> String {
        travelMonthFormatter.string(from: date)
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
