import Foundation

struct NinebotSharedStore {
    private enum Key {
        static let configuration = "ninebot.proxy.configuration"
        static let dataSourceMode = "ninebot.data.source.mode"
        static let resolvedAddresses = "ninebot.resolved.addresses"
        static let loginResult = "ninebot.login.result"
        static let portalLoginResult = "nineplus.portal.login.result"
        static let dashboard = "ninebot.dashboard.snapshot"
        static let lastError = "ninebot.last.error"
        static let lastAppRefreshEvent = "ninebot.last.app.refresh.event"
        static let lastWidgetRefreshEvent = "ninebot.last.widget.refresh.event"
        static let historyPrefix = "ninebot.vehicle.history."
        static let chargingSessionsPrefix = "ninebot.vehicle.charging.sessions."
        static let interfaceRidePrefix = "ninebot.vehicle.interface.rides."
        static let travelMonthSyncPrefix = "ninebot.vehicle.travel.month.sync.v2."
        static let vehicleImagePrefix = "ninebot.vehicle.image."
        static let recordedRides = "ninebot.recorded.rides"
        static let vehicleEvents = "ninebot.vehicle.events"
        static let pushDeviceToken = "ninebot.push.device.token"
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(suiteName: String = NinebotAppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func loadConfiguration() -> NinebotProxyConfiguration? {
        guard let data = defaults.data(forKey: Key.configuration) else { return nil }
        return try? decoder.decode(NinebotProxyConfiguration.self, from: data)
    }

    func saveConfiguration(_ configuration: NinebotProxyConfiguration) {
        guard let data = try? encoder.encode(configuration) else { return }
        defaults.set(data, forKey: Key.configuration)
    }

    func clearConfiguration() {
        defaults.removeObject(forKey: Key.configuration)
    }

    func loadDataSourceMode() -> NinebotDataSourceMode {
        guard let rawValue = defaults.string(forKey: Key.dataSourceMode),
              let mode = NinebotDataSourceMode(rawValue: rawValue) else {
            return .platform
        }
        return mode
    }

    func saveDataSourceMode(_ mode: NinebotDataSourceMode) {
        defaults.set(mode.rawValue, forKey: Key.dataSourceMode)
    }

    func loadPushDeviceToken() -> String? {
        let token = defaults.string(forKey: Key.pushDeviceToken)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    func savePushDeviceToken(_ token: String) {
        defaults.set(token, forKey: Key.pushDeviceToken)
    }

    func loadResolvedAddresses() -> [String: NinebotResolvedAddress] {
        guard let data = defaults.data(forKey: Key.resolvedAddresses),
              let addresses = try? decoder.decode([String: NinebotResolvedAddress].self, from: data) else {
            return [:]
        }
        return addresses
    }

    func saveResolvedAddresses(_ addresses: [String: NinebotResolvedAddress]) {
        guard let data = try? encoder.encode(addresses) else { return }
        defaults.set(data, forKey: Key.resolvedAddresses)
    }

    func loadLoginResult() -> NinebotLoginResult? {
        guard let data = defaults.data(forKey: Key.loginResult) else { return nil }
        return try? decoder.decode(NinebotLoginResult.self, from: data)
    }

    func saveLoginResult(_ result: NinebotLoginResult) {
        guard let data = try? encoder.encode(result) else { return }
        defaults.set(data, forKey: Key.loginResult)
    }

    func clearLoginResult() {
        defaults.removeObject(forKey: Key.loginResult)
    }

    func loadPortalLoginResult() -> NinePlusPortalLoginResult? {
        guard let data = defaults.data(forKey: Key.portalLoginResult) else { return nil }
        return try? decoder.decode(NinePlusPortalLoginResult.self, from: data)
    }

    func savePortalLoginResult(_ result: NinePlusPortalLoginResult) {
        guard let data = try? encoder.encode(result) else { return }
        defaults.set(data, forKey: Key.portalLoginResult)
    }

    func clearPortalLoginResult() {
        defaults.removeObject(forKey: Key.portalLoginResult)
    }

    func loadDashboard() -> NinebotDashboard? {
        guard let data = defaults.data(forKey: Key.dashboard) else { return nil }
        return try? decoder.decode(NinebotDashboard.self, from: data)
    }

    @discardableResult
    func saveDashboard(_ dashboard: NinebotDashboard) -> NinebotDashboard {
        // A fast dashboard refresh intentionally loads only the current month.
        // Preserve a previously known odometer value when the live status or
        // current-month endpoint does not return it, instead of replacing it
        // with "-- km" on the home screen.
        let dashboardWithCachedVehicles = preservingCachedVehicles(in: dashboard)
        let dashboardWithPreservedTotals = preservingKnownTotals(in: dashboardWithCachedVehicles)
        let archivedDashboard = dashboardWithArchivedInterfaceRides(dashboardWithPreservedTotals)
        guard let data = try? encoder.encode(archivedDashboard) else { return archivedDashboard }
        defaults.set(data, forKey: Key.dashboard)
        defaults.removeObject(forKey: Key.lastError)
        saveHistorySnapshots(for: archivedDashboard)
        return archivedDashboard
    }

    func loadHistory(sn: String) -> [NinebotVehicleHistoryPoint] {
        guard let data = defaults.data(forKey: historyKey(sn: sn)),
              let points = try? decoder.decode([NinebotVehicleHistoryPoint].self, from: data) else {
            return []
        }
        return points.sorted { $0.date < $1.date }
    }

    func loadVehicleEvents() -> [NinebotVehicleEvent] {
        guard let data = defaults.data(forKey: Key.vehicleEvents),
              let events = try? decoder.decode([NinebotVehicleEvent].self, from: data) else {
            return []
        }

        // v5 no longer treats an unlocked vehicle as an alarm. Remove records
        // written by older builds as well, so historical cache cannot bring
        // the deprecated “车辆当前未锁车” item back into notification cards.
        let filtered = events.filter { event in
            !(event.type == .alarm && event.detail.contains("车辆当前未锁车"))
        }
        if filtered.count != events.count {
            saveVehicleEvents(filtered)
        }
        return filtered.sorted { $0.occurredAt > $1.occurredAt }
    }

    func saveVehicleEvents(_ events: [NinebotVehicleEvent]) {
        let limited = Array(events.sorted { $0.occurredAt > $1.occurredAt }.prefix(200))
        guard let data = try? encoder.encode(limited) else { return }
        defaults.set(data, forKey: Key.vehicleEvents)
    }

    func loadRecordedRides() -> [NinebotRecordedRide] {
        guard let data = defaults.data(forKey: Key.recordedRides),
              let rides = try? decoder.decode([NinebotRecordedRide].self, from: data) else {
            return []
        }
        return rides.sorted { $0.startedAt > $1.startedAt }
    }

    func saveRecordedRides(_ rides: [NinebotRecordedRide]) {
        let limited = Array(rides.sorted { $0.startedAt > $1.startedAt }.prefix(120))
        guard let data = try? encoder.encode(limited) else { return }
        defaults.set(data, forKey: Key.recordedRides)
    }

    func upsertRecordedRide(_ ride: NinebotRecordedRide) {
        var rides = loadRecordedRides()
        if let index = rides.firstIndex(where: { $0.id == ride.id }) {
            rides[index] = ride
        } else {
            rides.insert(ride, at: 0)
        }
        saveRecordedRides(rides)
    }

    func deleteRecordedRide(id: String) {
        let rides = loadRecordedRides().filter { $0.id != id }
        saveRecordedRides(rides)
    }

    func saveLastError(_ message: String) {
        defaults.set(message, forKey: Key.lastError)
    }

    func loadLastError() -> String? {
        defaults.string(forKey: Key.lastError)
    }

    func loadLastAppRefreshEvent() -> NinebotRefreshEvent? {
        loadRefreshEvent(key: Key.lastAppRefreshEvent)
    }

    func saveLastAppRefreshEvent(_ event: NinebotRefreshEvent) {
        saveRefreshEvent(event, key: Key.lastAppRefreshEvent)
    }

    func loadLastWidgetRefreshEvent() -> NinebotRefreshEvent? {
        loadRefreshEvent(key: Key.lastWidgetRefreshEvent)
    }

    func saveLastWidgetRefreshEvent(_ event: NinebotRefreshEvent) {
        saveRefreshEvent(event, key: Key.lastWidgetRefreshEvent)
    }

    func loadChargingSessions(sn: String) -> [ChargingSession] {
        guard let data = defaults.data(forKey: chargingSessionsKey(sn: sn)),
              let sessions = try? decoder.decode([ChargingSession].self, from: data) else { return [] }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func upsertChargingSession(_ session: ChargingSession) {
        var sessions = loadChargingSessions(sn: session.vehicleSN)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        let limited = Array(sessions.sorted { $0.startedAt > $1.startedAt }.prefix(20))
        guard let data = try? encoder.encode(limited) else { return }
        defaults.set(data, forKey: chargingSessionsKey(sn: session.vehicleSN))
    }

    func historyCount(sn: String) -> Int {
        loadHistory(sn: sn).count
    }

    func interfaceRideCount(sn: String) -> Int {
        loadInterfaceRideRecords(sn: sn).count
    }

    func upsertInterfaceRideRecords(_ records: [NinebotRideRecord], sn: String) {
        guard !records.isEmpty else { return }
        let mergedRecords = mergeInterfaceRideRecords(
            incoming: records,
            stored: loadInterfaceRideRecords(sn: sn)
        )
        saveInterfaceRideRecords(mergedRecords, sn: sn)
    }

    /// Returns the complete local archive for one vehicle. Historical months are
    /// intentionally kept separate from the lightweight live-dashboard payload.
    func interfaceRideRecords(sn: String) -> [NinebotRideRecord] {
        loadInterfaceRideRecords(sn: sn)
    }

    /// A successful empty response is still a completed sync. Persisting that
    /// fact prevents every view reconstruction from repeatedly requesting a
    /// month that genuinely contains no rides.
    func travelMonthLastSyncedAt(sn: String, month: String) -> Date? {
        defaults.object(forKey: travelMonthSyncKey(sn: sn, month: month)) as? Date
    }

    func markTravelMonthSynced(sn: String, month: String, at date: Date = Date()) {
        defaults.set(date, forKey: travelMonthSyncKey(sn: sn, month: month))
    }

    func recordedRideCount() -> Int {
        loadRecordedRides().count
    }

    func storedDashboardByteCount() -> Int {
        defaults.data(forKey: Key.dashboard)?.count ?? 0
    }

    func loadVehicleImageData(sn: String) -> Data? {
        if let url = vehicleImageCacheURL(sn: sn),
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            return data
        }
        return defaults.data(forKey: vehicleImageFallbackKey(sn: sn))
    }

    func saveVehicleImageData(_ data: Data, sn: String) {
        guard !data.isEmpty, data.count <= 2_500_000 else { return }

        if let url = vehicleImageCacheURL(sn: sn) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if (try? data.write(to: url, options: .atomic)) != nil {
                defaults.removeObject(forKey: vehicleImageFallbackKey(sn: sn))
                return
            }
        }

        defaults.set(data, forKey: vehicleImageFallbackKey(sn: sn))
    }

    private func loadRefreshEvent(key: String) -> NinebotRefreshEvent? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(NinebotRefreshEvent.self, from: data)
    }

    private func saveRefreshEvent(_ event: NinebotRefreshEvent, key: String) {
        guard let data = try? encoder.encode(event) else { return }
        defaults.set(data, forKey: key)
    }

    private func preservingCachedVehicles(in dashboard: NinebotDashboard) -> NinebotDashboard {
        // A proxy restart or an eventually-consistent account endpoint can
        // briefly answer with an empty vehicles array. Keep the last verified
        // dashboard on disk until a non-empty live answer replaces it.
        guard dashboard.vehicles.isEmpty,
              let previous = loadDashboard(),
              !previous.vehicles.isEmpty else {
            return dashboard
        }
        return previous
    }

    private func preservingKnownTotals(in dashboard: NinebotDashboard) -> NinebotDashboard {
        guard let previous = loadDashboard() else { return dashboard }

        var merged = dashboard
        for index in merged.vehicles.indices {
            let sn = merged.vehicles[index].vehicle.sn
            guard let previousSnapshot = previous.vehicles.first(where: { $0.vehicle.sn == sn }) else {
                continue
            }

            if merged.vehicles[index].state.totalMileage == nil {
                merged.vehicles[index].state.totalMileage = previousSnapshot.state.totalMileage
            }
        }
        return merged
    }

    private func saveHistorySnapshots(for dashboard: NinebotDashboard) {
        for snapshot in dashboard.vehicles {
            let point = NinebotVehicleHistoryPoint(sn: snapshot.vehicle.sn, state: snapshot.state)
            var points = loadHistory(sn: snapshot.vehicle.sn)
            guard shouldAppend(point, after: points.last) else { continue }

            points.append(point)
            if points.count > 2400 {
                // Keep roughly one week of one-minute charging snapshots.
                // Older builds kept only 240 points, which made the weekly
                // charging view disappear after a short period.
                points.removeFirst(points.count - 2400)
            }

            guard let data = try? encoder.encode(points) else { continue }
            defaults.set(data, forKey: historyKey(sn: snapshot.vehicle.sn))
        }
    }

    private func dashboardWithArchivedInterfaceRides(_ dashboard: NinebotDashboard) -> NinebotDashboard {
        var archivedDashboard = dashboard

        for index in archivedDashboard.vehicles.indices {
            let sn = archivedDashboard.vehicles[index].vehicle.sn
            let incomingRecords = archivedDashboard.vehicles[index].state.rides
            guard !incomingRecords.isEmpty else {
                let storedRecords = loadInterfaceRideRecords(sn: sn)
                if !storedRecords.isEmpty {
                    archivedDashboard.vehicles[index].state.rideRecords = storedRecords
                }
                continue
            }

            let mergedRecords = mergeInterfaceRideRecords(
                incoming: incomingRecords,
                stored: loadInterfaceRideRecords(sn: sn)
            )
            saveInterfaceRideRecords(mergedRecords, sn: sn)
            archivedDashboard.vehicles[index].state.rideRecords = mergedRecords.isEmpty ? nil : mergedRecords
        }

        return archivedDashboard
    }

    private func loadInterfaceRideRecords(sn: String) -> [NinebotRideRecord] {
        guard let data = defaults.data(forKey: interfaceRideKey(sn: sn)),
              let records = try? decoder.decode([NinebotRideRecord].self, from: data) else {
            return []
        }
        return sortedInterfaceRideRecords(deduplicatedInterfaceRideRecords(records))
    }

    private func saveInterfaceRideRecords(_ records: [NinebotRideRecord], sn: String) {
        let limited = Array(sortedInterfaceRideRecords(deduplicatedInterfaceRideRecords(records)).prefix(500))
        guard let data = try? encoder.encode(limited) else { return }
        defaults.set(data, forKey: interfaceRideKey(sn: sn))
    }

    private func mergeInterfaceRideRecords(
        incoming: [NinebotRideRecord],
        stored: [NinebotRideRecord]
    ) -> [NinebotRideRecord] {
        var recordsByKey: [String: NinebotRideRecord] = [:]

        for record in stored {
            recordsByKey[interfaceRideKey(for: record)] = record
        }

        for record in incoming {
            recordsByKey[interfaceRideKey(for: record)] = record
        }

        return sortedInterfaceRideRecords(Array(recordsByKey.values))
    }

    private func deduplicatedInterfaceRideRecords(_ records: [NinebotRideRecord]) -> [NinebotRideRecord] {
        var recordsByKey: [String: NinebotRideRecord] = [:]

        for record in records {
            recordsByKey[interfaceRideKey(for: record)] = record
        }

        return Array(recordsByKey.values)
    }

    private func sortedInterfaceRideRecords(_ records: [NinebotRideRecord]) -> [NinebotRideRecord] {
        records.sorted { left, right in
            let leftDate = left.startedAt ?? left.endedAt ?? .distantPast
            let rightDate = right.startedAt ?? right.endedAt ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return interfaceRideKey(for: left) < interfaceRideKey(for: right)
        }
    }

    private func interfaceRideKey(for record: NinebotRideRecord) -> String {
        record.stableIdentityKey
    }

    private func shouldAppend(
        _ point: NinebotVehicleHistoryPoint,
        after last: NinebotVehicleHistoryPoint?
    ) -> Bool {
        guard let last else { return true }

        // The app polls every few seconds while charging. Keep a 10-second
        // charging sample cadence, while retaining charge-state transitions.
        // This gives the chart enough detail without unbounded growth.
        if point.isCharging != last.isCharging {
            return true
        }
        let minimumInterval: TimeInterval = point.isCharging == true ? 10 : 60
        if point.date.timeIntervalSince(last.date) < minimumInterval {
            return false
        }

        // A reversed timestamp or a duplicate timestamp must never corrupt the
        // time axis. The merge path below handles an occasional correction.
        guard point.date >= last.date else { return false }
        return true
    }

    private func historyKey(sn: String) -> String {
        "\(Key.historyPrefix)\(sn)"
    }

    private func chargingSessionsKey(sn: String) -> String {
        "\(Key.chargingSessionsPrefix)\(sn)"
    }

    private func interfaceRideKey(sn: String) -> String {
        "\(Key.interfaceRidePrefix)\(sn)"
    }

    private func travelMonthSyncKey(sn: String, month: String) -> String {
        "\(Key.travelMonthSyncPrefix)\(sn).\(month)"
    }

    private func vehicleImageFallbackKey(sn: String) -> String {
        "\(Key.vehicleImagePrefix)\(sn)"
    }

    private func vehicleImageCacheURL(sn: String) -> URL? {
        let baseURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NinebotAppGroup.identifier)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let fileName = sanitizedFileName(sn)
        return baseURL?
            .appendingPathComponent("VehicleImages", isDirectory: true)
            .appendingPathComponent("\(fileName).image")
    }

    private func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let text = String(scalars)
        return text.isEmpty ? "vehicle" : text
    }
}
