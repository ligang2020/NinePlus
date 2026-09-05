import Foundation

enum NinebotProxyError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "代理地址无效"
        case .invalidResponse:
            return "代理返回的数据格式无效"
        case .server(let message):
            return message
        case .httpStatus(let statusCode, let message):
            if message.isEmpty {
                return "HTTP \(statusCode)"
            }
            return "HTTP \(statusCode): \(message)"
        }
    }
}

struct NinebotProxyClient {
    var configuration: NinebotProxyConfiguration
    var session: URLSession = .shared

    func healthCheck() async throws -> JSONValue {
        try await request(method: "GET", path: ["healthz"])
    }

    func loginToNinePlus(username: String, password: String) async throws -> NinePlusPortalLoginResult {
        let payload = try await request(
            method: "POST",
            path: ["auth", "login"],
            body: [
                "username": username,
                "password": password,
            ]
        )
        return Self.portalLoginResult(from: payload)
    }

    func loginNinebotAccount(account: String, password: String) async throws -> NinebotLoginResult {
        let payload = try await request(
            method: "POST",
            path: ["ninebot", "login"],
            body: [
                "account": account,
                "password": password,
            ]
        )
        return Self.loginResult(from: payload)
    }

    // Legacy server-binding methods retained only for older app builds. The
    // current UI never calls them: devices authenticate with NinePlus and the
    // official cloud account is configured once on the server. New clients
    // must not expose these methods as a device login flow.
    func login(account: String, password: String) async throws -> NinebotLoginResult {
        try await loginNinebotAccount(account: account, password: password)
    }

    func platformLogin(account: String, password: String) async throws -> NinebotLoginResult {
        try await loginNinebotAccount(account: account, password: password)
    }

    func fetchCurrentPortalSession() async throws -> NinePlusPortalLoginResult {
        let payload = try await request(method: "GET", path: ["auth", "me"])
        return Self.portalLoginResult(from: payload)
    }

    func sendLoginCode(account: String) async throws {
        _ = try await request(
            method: "POST",
            path: ["auth", "login-code"],
            body: ["account": account]
        )
    }

    func sendPlatformLoginCode(account: String) async throws {
        _ = try await request(
            method: "POST",
            path: ["accounts", "login-code"],
            body: ["account": account]
        )
    }

    func consumeLoginCode(account: String, code: String) async throws -> NinebotLoginResult {
        let payload = try await request(
            method: "POST",
            path: ["auth", "login-code", "consume"],
            body: [
                "account": account,
                "code": code,
            ]
        )
        return Self.loginResult(from: payload)
    }

    func consumePlatformLoginCode(account: String, code: String) async throws -> NinebotLoginResult {
        let payload = try await request(
            method: "POST",
            path: ["accounts", "login-code", "consume"],
            body: [
                "account": account,
                "code": code,
            ]
        )
        return Self.loginResult(from: payload)
    }

    /// Renews the per-user NinePlus session. The server may either
    /// return a replacement token or refresh its cookie-backed session and
    /// return an empty payload; both outcomes are useful to the caller.
    func refreshNinePlusSession() async throws -> String? {
        let payload = try await request(
            method: "POST",
            path: ["auth", "refresh"],
            allowSessionRecovery: false
        )
        return Self.portalLoginResult(from: payload).sessionToken
    }

    func ringBell(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "bell"])
    }

    func openBucket(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "buck"])
    }

    func engineStart(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "engine", "start"])
    }

    func engineStop(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "engine", "stop"])
    }

    func fetchDashboard(selectedSN: String? = nil, forceRefresh: Bool = true) async throws -> NinebotDashboard {
        // Newer NinePlus servers aggregate the three live reads per vehicle and
        // apply a short session cache. Keep a 404/405 fallback so this app can
        // still work with an older container during a rolling deployment.
        do {
            var dashboardQuery = [URLQueryItem(name: "include_travel", value: "0")]
            if forceRefresh {
                dashboardQuery.append(URLQueryItem(name: "fresh", value: "1"))
            }
            let aggregatePayload = try await request(
                method: "GET",
                path: ["dashboard"],
                queryItems: dashboardQuery
            )
            if let dashboard = Self.dashboard(from: aggregatePayload, selectedSN: selectedSN) {
                // The optimized server snapshot deliberately omits BMS and
                // travel payloads. Hydrate those missing fields before returning
                // so the home screen never settles on a permanently partial
                // state with blank mileage and charging metrics.
                return await hydrateDashboardIfNeeded(dashboard, month: Self.currentMonthString())
            }
        } catch let error as NinebotProxyError {
            switch error {
            case .httpStatus(let status, _) where status == 404 || status == 405:
                break
            default:
                throw error
            }
        }

        let vehiclesPayload = try await request(method: "GET", path: ["vehicles"])
        let vehicleValues = Self.arrayPayload(from: vehiclesPayload, preferredKeys: ["vehicles", "data"])
        let vehicles = vehicleValues.compactMap(Self.vehicleInfo)
        let currentMonth = Self.currentMonthString()
        let fetchedAt = Date()

        var snapshots: [NinebotVehicleSnapshot] = []
        for vehicle in vehicles {
            // The home screen needs the current state only.  The previous
            // implementation also fetched every month since the vehicle was
            // bound, serially, which turned one refresh into dozens of
            // ninecli calls.  Historical months are loaded by the travel
            // screen through syncTravelMonth(_:month:pageSize:).
            async let statusPayload: JSONValue? = try? await request(
                method: "GET",
                path: ["vehicles", vehicle.sn, "status"]
            )
            async let travelPayload: JSONValue? = try? await fetchTravel(
                sn: vehicle.sn,
                month: currentMonth
            )
            async let batteryPayload: JSONValue? = try? await request(
                method: "GET",
                path: ["vehicles", vehicle.sn, "battery"]
            )

            let status = await statusPayload
            let travel = await travelPayload
            let battery = await batteryPayload
            let state = Self.vehicleState(
                status: status,
                travel: travel,
                battery: battery,
                updatedAt: fetchedAt
            )
            let resolvedVehicle = Self.vehicleInfo(vehicle, addingImageFrom: status, battery: battery)
            snapshots.append(NinebotVehicleSnapshot(vehicle: resolvedVehicle, state: state))
        }

        let resolvedSelectedSN: String?
        if let selectedSN, snapshots.contains(where: { $0.vehicle.sn == selectedSN }) {
            resolvedSelectedSN = selectedSN
        } else {
            resolvedSelectedSN = snapshots.first?.vehicle.sn
        }

        return NinebotDashboard(
            vehicles: snapshots,
            selectedSN: resolvedSelectedSN,
            updatedAt: fetchedAt
        )
    }

    private func hydrateDashboardIfNeeded(_ dashboard: NinebotDashboard, month: String) async -> NinebotDashboard {
        guard !dashboard.vehicles.isEmpty else { return dashboard }

        var hydrated = dashboard
        for index in hydrated.vehicles.indices {
            let current = hydrated.vehicles[index]
            let needsStatus = current.state.isCharging == nil
                || current.state.totalMileage == nil
                || current.state.battery == nil
            let needsBattery = current.state.batteryVoltage == nil
                || current.state.batteryTemperature == nil
                || current.state.batteryCycleCount == nil
                || current.state.chargingPower == nil
            let needsTravel = current.state.todayMileage == nil
                || current.state.monthMileage == nil

            async let statusResult: JSONValue? = needsStatus
                ? (try? await request(method: "GET", path: ["vehicles", current.vehicle.sn, "status"]))
                : nil
            async let batteryResult: JSONValue? = needsBattery
                ? (try? await request(method: "GET", path: ["vehicles", current.vehicle.sn, "battery"]))
                : nil
            async let travelResult: JSONValue? = needsTravel
                ? (try? await fetchTravel(sn: current.vehicle.sn, month: month))
                : nil

            let status = await statusResult
            let battery = await batteryResult
            let travel = await travelResult
            guard status != nil || battery != nil || travel != nil else { continue }

            let parsed = Self.vehicleState(
                status: status ?? current.state.rawStatus.map(JSONValue.object),
                travel: travel ?? current.state.rawTravel.map(JSONValue.object),
                battery: battery ?? current.state.rawBattery.map(JSONValue.object),
                updatedAt: current.state.updatedAt
            )
            var merged = parsed
            merged.battery = parsed.battery ?? current.state.battery
            merged.batteryVoltage = parsed.batteryVoltage ?? current.state.batteryVoltage
            merged.batteryTemperature = parsed.batteryTemperature ?? current.state.batteryTemperature
            merged.batteryCycleCount = parsed.batteryCycleCount ?? current.state.batteryCycleCount
            merged.chargingPower = parsed.chargingPower ?? current.state.chargingPower
            merged.totalMileage = parsed.totalMileage ?? current.state.totalMileage
            merged.monthMileage = parsed.monthMileage ?? current.state.monthMileage
            merged.lastMileage = parsed.lastMileage ?? current.state.lastMileage
            merged.rideRecords = parsed.rideRecords ?? current.state.rideRecords
            merged.dailyMileageRecords = parsed.dailyMileageRecords ?? current.state.dailyMileageRecords
            merged.serverPrediction = current.state.serverPrediction
            hydrated.vehicles[index].state = merged
        }
        return hydrated
    }

    /// Loads the detail payload separately from the fast dashboard. The server
    /// intentionally omits this heavier read from `/dashboard`; callers can
    /// hydrate the battery card after the first screen has rendered.
    func fetchBattery(sn: String) async throws -> JSONValue {
        try await request(
            method: "GET",
            path: ["vehicles", sn, "battery"]
        )
    }

    func fetchTravelDetail(sn: String, travelID: String) async throws -> NinebotRideDetail {
        let payload = try await request(
            method: "GET",
            path: ["vehicles", sn, "travel", travelID]
        )

        return NinebotRideDetail(
            vehicleSN: sn,
            rideID: travelID,
            fetchedAt: Date(),
            raw: payload,
            parsedRecord: Self.rideRecord(from: payload, index: 0)
        )
    }

    /// Loads one month of trips without forcing the fast dashboard endpoint to
    /// include travel. The dashboard is intentionally lightweight; the view
    /// model calls this in a cancellable background enrichment task so vehicle
    /// status appears immediately while trip records still populate shortly
    /// afterwards.
    func fetchTravelMonth(sn: String, month: String) async throws -> NinebotTravelPage {
        let payload = try await fetchTravel(sn: sn, month: month)
        return Self.travelPage(from: payload, fallbackMonth: month)
    }

    func syncTravelMonth(sn: String, month: String, pageSize: Int = 20) async throws -> NinebotTravelPage {
        // A historical month is assembled from the official cloud's paged
        // archive. Keep ordinary live requests responsive, but give this
        // explicit user-initiated archive sync enough time to finish.
        let payload = try await request(
            method: "POST",
            path: ["vehicles", sn, "travel-sync"],
            queryItems: [
                URLQueryItem(name: "month", value: month),
                URLQueryItem(name: "page_size", value: "\(pageSize)")
            ],
            timeoutInterval: 120
        )
        return Self.travelPage(from: payload, fallbackMonth: month)
    }

    private func fetchTravel(sn: String, month: String) async throws -> JSONValue {
        try await request(
            method: "GET",
            path: ["vehicles", sn, "travel"],
            queryItems: [URLQueryItem(name: "month", value: month)]
        )
    }

    func registerPushDevice(token: String, bundleID: String, environment: String) async throws {
        _ = try await request(
            method: "POST",
            path: ["devices", "register"],
            body: [
                "token": token,
                "bundle_id": bundleID,
                "environment": environment,
            ]
        )
    }

    private func request(
        method: String,
        path: [String],
        queryItems: [URLQueryItem] = [],
        body: [String: String]? = nil,
        timeoutInterval: TimeInterval = 20,
        allowSessionRecovery: Bool = true
    ) async throws -> JSONValue {
        let url = try buildURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        // The dashboard is explicitly a live read. Do not let URLSession reuse
        // an older cached HTTP response when the app returns from background.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        // An optional deployment Bearer token protects the entire API,
        // including APNs device registration. It is never embedded at build
        // time and is supplied by the user only when the server requires it.
        let bearerToken = configuration.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        // The per-user NinePlus session is validated by protected endpoints.
        if let sessionToken = configuration.appSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-NinePlus-Session")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NinebotProxyError.invalidResponse
        }

        // A server restart can clear the in-memory session. Retry without the
        // stale header once; the view model then asks /auth/refresh and replays
        // the request using the renewed NinePlus session.
        if httpResponse.statusCode == 401,
           allowSessionRecovery,
           configuration.appSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            var recoveredConfiguration = configuration
            recoveredConfiguration.appSessionToken = nil
            return try await NinebotProxyClient(
                configuration: recoveredConfiguration,
                session: session
            ).request(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                allowSessionRecovery: false
            )
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            throw NinebotProxyError.httpStatus(httpResponse.statusCode, Self.errorMessage(from: data))
        }

        if data.isEmpty {
            return .object([:])
        }

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        return try Self.unwrapEnvelope(root)
    }

    private func buildURL(path: [String], queryItems: [URLQueryItem]) throws -> URL {
        guard var url = configuration.baseURL else {
            throw NinebotProxyError.invalidBaseURL
        }

        for component in path {
            url.appendPathComponent(component)
        }

        guard !queryItems.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NinebotProxyError.invalidBaseURL
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw NinebotProxyError.invalidBaseURL
        }
        return finalURL
    }
}

extension NinebotProxyClient {
    static func unwrapEnvelope(_ root: JSONValue) throws -> JSONValue {
        guard let object = root.objectValue, object.keys.contains("ok") else {
            return root
        }

        if object["ok"]?.boolValue == true {
            return object["data"] ?? .object([:])
        }

        let error = object["error"]?.objectValue
        let message = error?["message"]?.stringValue
            ?? error?["code"]?.stringValue
            ?? "九号代理请求失败"
        throw NinebotProxyError.server(message)
    }

    static func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let object = root.objectValue {
                if let error = object["error"]?.objectValue {
                    return error["message"]?.stringValue ?? error["code"]?.stringValue ?? ""
                }
                return object["message"]?.stringValue ?? ""
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func portalLoginResult(from value: JSONValue) -> NinePlusPortalLoginResult {
        let object = value.objectValue ?? [:]
        return NinePlusPortalLoginResult(
            username: object["username"]?.stringValue ?? "",
            sessionToken: object["session_token"]?.stringValue ?? object["sessionToken"]?.stringValue,
            expiresAt: object["expires_at"]?.doubleValue ?? object["expiresAt"]?.doubleValue,
            officialAccountBound: object["official_account_bound"]?.boolValue ?? object["officialAccountBound"]?.boolValue ?? false,
            officialAccount: object["official_account"]?.stringValue ?? object["officialAccount"]?.stringValue
        )
    }

    static func loginResult(from value: JSONValue) -> NinebotLoginResult {
        let object = value.objectValue ?? [:]
        return NinebotLoginResult(
            uuid: object["uuid"]?.stringValue,
            phone: object["phone"]?.stringValue,
            areaCode: object["area_code"]?.stringValue,
            region: object["region"]?.stringValue,
            businessUID: object["business_uid"]?.stringValue,
            accountID: object["account_id"]?.intValue ?? object["id"]?.intValue,
            sessionToken: object["session_token"]?.stringValue ?? object["sessionToken"]?.stringValue
        )
    }

    static func dateValue(_ value: JSONValue) -> Date? {
        guard let number = value.doubleValue ?? value.stringValue.flatMap(Double.init), number > 0 else {
            return nil
        }
        let seconds = number > 1_000_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    static func dashboard(from value: JSONValue, selectedSN: String?) -> NinebotDashboard? {
        guard let object = value.objectValue,
              let entries = object["vehicles"]?.arrayValue else {
            return nil
        }

        let fetchedAt = object["updated_at"].flatMap(Self.dateValue) ?? Date()
        let snapshots = entries.compactMap { entry -> NinebotVehicleSnapshot? in
            guard let row = entry.objectValue,
                  let vehicleValue = row["vehicle"],
                  let vehicle = vehicleInfo(from: vehicleValue) else {
                return nil
            }

            let status = row["status"]
            let travel = row["travel"]
            let battery = row["battery"]
            let state = vehicleState(
                status: status,
                travel: travel,
                battery: battery,
                updatedAt: fetchedAt
            )
            let resolvedVehicle = vehicleInfo(vehicle, addingImageFrom: status, battery: battery)
            return NinebotVehicleSnapshot(vehicle: resolvedVehicle, state: state)
        }

        // An empty aggregate is a valid response for an account with no bound
        // vehicles, but a malformed response should use the legacy fallback.
        guard entries.isEmpty || !snapshots.isEmpty else { return nil }
        let resolvedSelectedSN: String?
        if let selectedSN, snapshots.contains(where: { $0.vehicle.sn == selectedSN }) {
            resolvedSelectedSN = selectedSN
        } else {
            resolvedSelectedSN = snapshots.first?.vehicle.sn
        }
        return NinebotDashboard(
            vehicles: snapshots,
            selectedSN: resolvedSelectedSN,
            updatedAt: fetchedAt
        )
    }

    static func arrayPayload(from value: JSONValue, preferredKeys: [String]) -> [JSONValue] {
        if let array = value.arrayValue {
            return array
        }

        guard let object = value.objectValue else {
            return []
        }

        for key in preferredKeys {
            if let array = object[key]?.arrayValue {
                return array
            }
        }

        return []
    }

    static func vehicleInfo(from value: JSONValue) -> NinebotVehicleInfo? {
        guard let object = value.objectValue else { return nil }
        guard let sn = firstString(["wnumber", "sn"], in: object), !sn.isEmpty else {
            return nil
        }

        var model = firstString(["vehicle_name_en", "vehicle_name", "model", "vehicleModel"], in: object) ?? sn
        if let vehicleType = object["vehicle_type"]?.stringValue, !vehicleType.isEmpty {
            model = "\(model) (\(vehicleType))"
        }

        return NinebotVehicleInfo(
            sn: sn,
            name: firstString(["device_name", "deviceName"], in: object) ?? sn,
            model: model,
            imageURLString: firstString(["v6_light_img_url", "img_url", "img"], in: object),
            raw: object
        )
    }

    static func vehicleInfo(_ vehicle: NinebotVehicleInfo, addingImageFrom status: JSONValue?, battery: JSONValue?) -> NinebotVehicleInfo {
        guard vehicle.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return vehicle
        }

        let statusObject = status?.objectValue ?? [:]
        let batteryObject = battery?.objectValue ?? [:]
        guard let imageURLString = firstString(
            ["v6_light_img_url", "v6LightImgUrl", "img_url", "imgUrl", "img", "image_url", "imageUrl"],
            in: statusObject
        ) ?? firstString(
            ["v6_light_img_url", "v6LightImgUrl", "img_url", "imgUrl", "img", "image_url", "imageUrl"],
            in: batteryObject
        ) else {
            return vehicle
        }

        var resolved = vehicle
        resolved.imageURLString = imageURLString
        return resolved
    }

    static func travelPage(from value: JSONValue, fallbackMonth: String) -> NinebotTravelPage {
        let object = value.objectValue ?? [:]
        // `/travel-sync` returns its rows as `records` (and also `items`),
        // while upstream/legacy reads may use `list`, `rows`, `travels`, or a
        // root array. Accept every documented shape so a successful historical
        // month response cannot be parsed as an empty list on iOS.
        var resolvedRides: [JSONValue]?
        for key in ["records", "items", "list", "rows", "travels"] {
            if let rides = object[key]?.arrayValue {
                resolvedRides = rides
                break
            }
        }
        let rides = resolvedRides ?? value.arrayValue ?? []
        let archiveDateFallbacks = safeArchiveDateFallbacks(for: rides, expectedMonth: fallbackMonth)
        var records = rides.enumerated().compactMap { index, value -> NinebotRideRecord? in
            guard var record = rideRecord(from: value, index: index) else { return nil }
            // Some monthly archives expose only a date-only field. It is safe
            // to use only when dates vary within the month; an identical date
            // for every row is the monthly statement marker, not trip time.
            if record.startedAt == nil {
                record.startedAt = archiveDateFallbacks[index]
            }
            return record
        }
        if hasRepeatedMonthlyStatementDate(records, expectedMonth: fallbackMonth) {
            records.indices.forEach { records[$0].startedAt = nil }
        }
        return NinebotTravelPage(
            month: firstString(["month"], in: object) ?? fallbackMonth,
            page: object["page"]?.intValue ?? 1,
            pageSize: object["page_size"]?.intValue ?? object["pageSize"]?.intValue ?? records.count,
            total: object["total"]?.intValue ?? object["times"]?.intValue ?? records.count,
            hasMore: object["has_more"]?.boolValue ?? object["hasMore"]?.boolValue ?? false,
            records: records,
            raw: value
        )
    }

    static func vehicleState(status: JSONValue?, travel: JSONValue?, battery: JSONValue? = nil, updatedAt: Date) -> NinebotVehicleState {
        let statusRoot = status?.objectValue ?? [:]
        let statusObject = payloadObject(statusRoot, preferredKeys: ["status", "vehicle_status", "vehicleStatus", "data"])
        let travelRoot = travel?.objectValue ?? [:]
        let travelObject = payloadObject(travelRoot, preferredKeys: ["travel", "travels", "data"])
        let batteryRoot = battery?.objectValue ?? [:]
        let batteryPayloadObject = payloadObject(batteryRoot, preferredKeys: ["battery", "batteryInfo", "battery_info", "bms", "bmsInfo", "bms_info", "data"])
        let batteryObject = firstObject(["battery", "batteryInfo", "battery_info", "bms", "bmsInfo", "bms_info"], in: statusObject)
            ?? firstObject(["battery", "batteryInfo", "battery_info", "bms", "bmsInfo", "bms_info"], in: statusRoot)
            ?? [:]
        let batteryListObject = firstArrayObject(["battery_list", "batteryList", "batteries", "packs", "batteryPack"], in: batteryPayloadObject)
            ?? firstArrayObject(["battery_list", "batteryList", "batteries", "packs", "batteryPack"], in: batteryRoot)
            ?? [:]
        let batteryMainObject = firstObject(["battery_main", "batteryMain"], in: batteryPayloadObject)
            ?? firstObject(["battery_main", "batteryMain"], in: batteryRoot)
            ?? [:]
        // BMS responses differ by vehicle firmware: some versions put the
        // readings directly on the root, others nest them under `data`,
        // `battery_info`, `bms_data`, or one of several battery-pack arrays.
        // Flatten all object containers before looking up telemetry so a valid
        // response cannot turn into four empty cards just because its wrapper
        // depth changed.
        let batterySources = Self.nestedObjects(
            roots: [statusObject, statusRoot, batteryObject, batteryPayloadObject, batteryRoot, batteryListObject, batteryMainObject],
            maxDepth: 4
        )
        let loc = statusObject["loc"]?.objectValue
        let locationInfo = statusObject["locationInfo"]?.objectValue
        let lockNumber = loc?["lock"]?.intValue ?? statusObject["lock_status"]?.intValue
        let rides = travelObject["list"]?.arrayValue ?? []
        let rideRecords = rides.enumerated().compactMap { index, value in
            rideRecord(from: value, index: index)
        }
        let lastRide = rideRecords.first
        let dailyMileageRecords = dailyMileageRecords(from: travelObject)

        return NinebotVehicleState(
            battery: firstInt(["dump_energy", "dumpEnergy"], in: statusObject)
                ?? firstInt(["electricity", "dump_energy", "dumpEnergy"], in: batteryPayloadObject)
                ?? firstInt(["electricity", "dump_energy", "dumpEnergy", "soc", "battery", "battery_percent", "batteryPercent"], in: batteryListObject)
                ?? firstInt(["electricity", "dump_energy", "dumpEnergy", "soc", "battery", "battery_percent", "batteryPercent"], in: batterySources),
            batteryVoltage: normalizedBatteryVoltage(
                firstDouble(
                    [
                        "battery_voltage",
                        "batteryVoltage",
                        "battery_vol",
                        "batteryVol",
                        "batt_voltage",
                        "battVoltage",
                        "bat_voltage",
                        "batVoltage",
                        "bms_voltage",
                        "bmsVoltage",
                        "bms_volt",
                        "bmsVolt",
                        "batt_volt",
                        "battVolt",
                        "voltage",
                        "volt"
                    ],
                    in: batterySources
                )
            ),
            batteryTemperature: normalizedBatteryTemperature(
                firstDouble(
                    [
                        "battery_temperature",
                        "batteryTemperature",
                        "battery_temp",
                        "batteryTemp",
                        "batt_temperature",
                        "battTemperature",
                        "batt_temp",
                        "battTemp",
                        "bat_temperature",
                        "batTemperature",
                        "bat_temp",
                        "batTemp",
                        "bms_temperature",
                        "bmsTemperature",
                        "bms_temp",
                        "bmsTemp",
                        "bat_temp",
                        "batTemp",
                        "temp_c",
                        "tempC",
                        "temperature_c",
                        "temperatureC",
                        "temperature",
                        "temp"
                    ],
                    in: batterySources
                )
            ),
            batteryCycleCount: firstInt(["bms_cycle", "bmsCycle", "bms_cycles", "bmsCycles", "cycle_count", "cycleCount", "cycle", "cycles"], in: batterySources),
            chargingPower: firstDouble(["charging_power", "chargingPower", "charge_power", "chargePower", "power", "charge_watt", "chargeWatt", "charging_watt", "chargingWatt", "power_w", "powerW"], in: batterySources),
            interfaceMaximumSpeed: firstDouble(["max_speed", "maxSpeed", "highest_speed", "highestSpeed", "peak_speed", "peakSpeed", "top_speed", "topSpeed"], in: [statusObject, travelObject, batteryPayloadObject])
                .flatMap { $0 > 0 && $0 <= 120 ? $0 : nil },
            endurance: firstDouble(["precise_estimate_mileage", "preciseEstimateMileage", "estimate_mileage", "estimateMileage"], in: statusObject),
            aiEstimatedMileage: firstDouble(["ai_estimate_mileage", "aiEstimateMileage", "ai_estimated_mileage", "aiEstimatedMileage"], in: statusObject),
            isCharging: firstBoolLike(["charging", "chargingState"], in: statusObject, trueValue: 1)
                ?? firstBoolLike(["charging", "chargingState"], in: batteryPayloadObject, trueValue: 1),
            isPoweredOn: firstBoolLike(["pwr", "powerStatus"], in: statusObject, trueValue: 1),
            isLocked: lockNumber.map { $0 == 1 },
            remainingChargeTime: firstDouble(["remain_charge_time", "remainChargeTime", "remainingChargeTime"], in: statusObject)
                ?? firstDouble(["remain_charge_time", "remainChargeTime", "remainingChargeTime"], in: batteryPayloadObject),
            locationDescription: firstString(["locationDesc", "desc"], in: locationInfo ?? [:]),
            latitude: normalizedCoordinate(
                loc?["lat"]?.doubleValue ?? locationInfo?["lat"]?.doubleValue,
                limit: 90
            ),
            longitude: normalizedCoordinate(
                loc?["lon"]?.doubleValue ?? locationInfo?["lon"]?.doubleValue,
                limit: 180
            ),
            totalMileage: firstDouble(["total_mileage_odo", "totalMileageOdo", "total_mileage", "totalMileage", "total_mileages"], in: statusObject)
                ?? firstDouble(["total_mileage_odo", "totalMileageOdo", "total_mileage", "totalMileage"], in: statusRoot)
                ?? firstDouble(["total_mileage", "totalMileage", "total_mileages"], in: travelObject),
            monthMileage: firstDouble(["total_mileages", "monthMileage"], in: travelObject),
            monthEnergy: firstDouble(["ec", "monthEnergy"], in: travelObject),
            monthUsedElectricity: firstDouble(["used_electricity", "usedElectricity"], in: travelObject),
            lastMileage: lastRide?.mileage
                ?? firstDouble(["last_mileage", "lastMileage", "current_mileage", "currentMileage", "trip_mileage", "tripMileage", "ride_mileage", "rideMileage", "driving_mileage", "drivingMileage"], in: [statusObject])
                ?? firstDouble(["last_mileage", "lastMileage", "current_mileage", "currentMileage", "trip_mileage", "tripMileage", "ride_mileage", "rideMileage", "driving_mileage", "drivingMileage"], in: [travelObject]),
            lastEnergy: lastRide?.energy,
            lastUsedElectricity: lastRide?.usedElectricity,
            rideRecords: rideRecords.isEmpty ? nil : rideRecords,
            dailyMileageRecords: dailyMileageRecords.isEmpty ? nil : dailyMileageRecords,
            updatedAt: updatedAt,
            rawStatus: statusObject.isEmpty ? nil : statusObject,
            rawTravel: travelObject.isEmpty ? nil : travelObject,
            rawBattery: batteryPayloadObject.isEmpty ? nil : batteryPayloadObject
        )
    }

    static func normalizedCoordinate(_ value: Double?, limit: Double) -> Double? {
        guard let value else { return nil }
        if abs(value) <= limit { return value }

        for divisor in [1_000_000.0, 10_000_000.0, 100_000.0] {
            let normalized = value / divisor
            if abs(normalized) <= limit {
                return normalized
            }
        }

        return nil
    }

    static func rideRecord(from value: JSONValue, index: Int) -> NinebotRideRecord? {
        guard let object = value.objectValue else { return nil }
        let timeObjects = tripTimeObjects(from: object)
        // `date` / `day` in the monthly archive can be the statement date
        // (commonly the last day of the selected month), not a ride start.
        // Only use explicit trip start/end fields so one month-end marker
        // cannot make every historical ride appear to happen on that day.
        let startedAt = firstTripDate(
            [
                "start_time", "startTime", "start_at", "startAt", "start_timestamp", "startTimestamp", "start_ts", "startTs",
                "begin_time", "beginTime", "begin_at", "beginAt", "begin_timestamp", "beginTimestamp", "begin_ts", "beginTs",
                "travel_start_time", "travelStartTime", "travel_start_at", "travelStartAt", "travel_start_timestamp", "travelStartTimestamp",
                "travel_begin_time", "travelBeginTime", "travel_begin_at", "travelBeginAt", "begin_date", "beginDate",
                "start_date_time", "startDateTime", "start_datetime", "startDatetime", "started_at", "startedAt",
                "departure_time", "departureTime", "ride_start_time", "rideStartTime", "ride_start_at", "rideStartAt",
                "start_time_ms", "startTimeMs", "stime", "travel_timestamp", "travelTimestamp"
            ],
            in: timeObjects
        )
        let endedAt = firstTripDate(
            [
                "end_time", "endTime", "end_at", "endAt", "end_timestamp", "endTimestamp", "end_ts", "endTs",
                "stop_time", "stopTime", "stop_at", "stopAt", "stop_timestamp", "stopTimestamp", "finish_time", "finishTime",
                "finish_at", "finishAt", "finish_timestamp", "finishTimestamp", "travel_end_time", "travelEndTime",
                "travel_end_at", "travelEndAt", "travel_end_timestamp", "travelEndTimestamp", "end_date_time", "endDateTime",
                "end_datetime", "endDatetime", "ended_at", "endedAt", "arrival_time", "arrivalTime", "ride_end_time", "rideEndTime",
                "ride_end_at", "rideEndAt", "end_time_ms", "endTimeMs", "end_date", "endDate", "etime"
            ],
            in: timeObjects
        )
        let mileage = firstDouble(["mileages", "mileage", "distance", "rideMileage"], in: object)
        let energy = firstDouble(["ec", "energy", "electricity", "consume"], in: object)
        let usedElectricity = firstDouble(["used_electricity", "usedElectricity", "usedElectric", "useElectricity"], in: object)
        let durationMinutes = firstDurationMinutes(in: object, startedAt: startedAt, endedAt: endedAt)
        let speed = firstDouble(["max_speed", "maxSpeed", "highest_speed", "highestSpeed", "peak_speed", "peakSpeed", "top_speed", "topSpeed", "speed"], in: object)

        let id = firstString(["travel_id", "travelId", "ride_id", "rideId", "record_id", "recordId", "id"], in: object)
            ?? startedAt.map { "\(Int($0.timeIntervalSince1970))" }
            ?? "\(index)"

        return NinebotRideRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            mileage: mileage,
            energy: energy,
            usedElectricity: usedElectricity,
            durationMinutes: durationMinutes,
            speed: speed,
            raw: object
        )
    }

    static func dailyMileageRecords(from travelObject: [String: JSONValue]) -> [NinebotDailyMileageRecord] {
        var detail: [JSONValue]? = travelObject["detail"]?.arrayValue
        if detail == nil { detail = travelObject["daily"]?.arrayValue }
        if detail == nil { detail = travelObject["daily_mileage"]?.arrayValue }
        if detail == nil { detail = travelObject["dailyMileage"]?.arrayValue }
        if detail == nil { detail = travelObject["day_list"]?.arrayValue }
        if detail == nil { detail = travelObject["days"]?.arrayValue }
        guard let detail, !detail.isEmpty else { return [] }

        let month = firstString(["month", "month_id", "monthId"], in: travelObject)
        let currentMonth = currentMonthString()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTimeZone
        let currentDay = calendar.component(.day, from: Date())

        return detail.enumerated().compactMap { index, value in
            let object = value.objectValue
            let mileage: Double?
            if let number = value.doubleValue {
                mileage = number
            } else if let object {
                mileage = firstDouble(
                    ["mileage", "mileages", "day_mileage", "dayMileage", "day_total_mileage", "dayTotalMileage", "distance", "total_mileage", "totalMileage"],
                    in: object
                )
            } else {
                mileage = nil
            }
            guard let mileage, mileage.isFinite, mileage >= 0 else { return nil }

            // Prefer an explicit date/day supplied by the cloud. The old
            // index-only mapping was wrong when `detail` was latest-first or
            // contained sparse days, which made today's mileage disappear.
            let explicitDate = object.flatMap { firstDate(["date", "day_date", "dayDate", "time", "timestamp"], in: $0) }
            let explicitDay = object.flatMap { firstInt(["day", "day_no", "dayNo"], in: $0) }
                ?? explicitDate.flatMap { calendar.component(.day, from: $0) }
            let day = explicitDay ?? (index + 1)
            guard (1...31).contains(day) else { return nil }

            // If the current month payload is sparse, do not truncate based on
            // array position. Positional numeric arrays still use the current
            // day limit for compatibility with the original API shape.
            if month == currentMonth, explicitDay == nil, object == nil, day > currentDay {
                return nil
            }
            let recordDate = explicitDate ?? date(month: month, day: day)
            return NinebotDailyMileageRecord(
                id: "\(month ?? currentMonth)-\(day)-\(index)",
                day: day,
                date: recordDate,
                mileage: mileage
            )
        }
    }

    static func payloadObject(_ root: [String: JSONValue], preferredKeys: [String]) -> [String: JSONValue] {
        var current = root
        for _ in 0..<2 {
            guard let nested = firstObject(preferredKeys, in: current), !nested.isEmpty else { break }
            current = nested
        }
        return current
    }

    static func nestedObjects(roots: [[String: JSONValue]], maxDepth: Int) -> [[String: JSONValue]] {
        guard maxDepth > 0 else { return roots }
        var result: [[String: JSONValue]] = []
        var queue: [(object: [String: JSONValue], depth: Int)] = roots.map { ($0, 0) }
        var index = 0
        while index < queue.count {
            let item = queue[index]
            index += 1
            result.append(item.object)
            guard item.depth < maxDepth else { continue }
            for value in item.object.values {
                if let child = value.objectValue {
                    queue.append((child, item.depth + 1))
                } else if let children = value.arrayValue {
                    for child in children {
                        if let childObject = child.objectValue {
                            queue.append((childObject, item.depth + 1))
                        }
                    }
                }
            }
        }
        return result
    }

    static func firstInt(_ keys: [String], in object: [String: JSONValue]) -> Int? {
        for key in keys {
            if let value = object[key]?.intValue {
                return value
            }
        }
        return nil
    }

    static func firstInt(_ keys: [String], in objects: [[String: JSONValue]]) -> Int? {
        for object in objects {
            if let value = firstInt(keys, in: object) {
                return value
            }
        }
        return nil
    }

    static func firstDouble(_ keys: [String], in object: [String: JSONValue]) -> Double? {
        for key in keys {
            if let value = object[key]?.doubleValue {
                return value
            }
        }
        return nil
    }

    static func firstDouble(_ keys: [String], in objects: [[String: JSONValue]]) -> Double? {
        for object in objects {
            if let value = firstDouble(keys, in: object) {
                return value
            }
        }
        return nil
    }

    static func firstString(_ keys: [String], in object: [String: JSONValue]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func firstObject(_ keys: [String], in object: [String: JSONValue]) -> [String: JSONValue]? {
        for key in keys {
            if let value = object[key]?.objectValue {
                return value
            }
        }
        return nil
    }

    static func firstArrayObject(_ keys: [String], in object: [String: JSONValue]) -> [String: JSONValue]? {
        for key in keys {
            guard let array = object[key]?.arrayValue else { continue }
            for value in array {
                if let objectValue = value.objectValue {
                    return objectValue
                }
            }
        }
        return nil
    }

    static func normalizedBatteryVoltage(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value > 1_000 {
            return value / 1_000
        }
        if value > 120 {
            return value / 10
        }
        return value
    }

    static func normalizedBatteryTemperature(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if abs(value) > 120 {
            return value / 10
        }
        return value
    }

    static func firstDate(_ keys: [String], in object: [String: JSONValue]) -> Date? {
        for key in keys {
            if let value = dateValue(object[key]) {
                return value
            }
        }
        return nil
    }

    static func firstTripDate(_ keys: [String], in objects: [[String: JSONValue]]) -> Date? {
        for object in objects {
            if let date = firstDate(keys, in: object) {
                return date
            }
        }
        return nil
    }

    static func tripTimeObjects(from object: [String: JSONValue]) -> [[String: JSONValue]] {
        let containerKeys = [
            "detail", "travel", "ride", "trip", "data", "record", "result", "item", "content",
            "travel_detail", "travelDetail", "travel_info", "travelInfo", "trip_info", "tripInfo"
        ]
        var objects: [[String: JSONValue]] = []
        var pending: [([String: JSONValue], Int)] = [(object, 0)]

        while let (current, depth) = pending.popLast() {
            objects.append(current)
            guard depth < 3 else { continue }
            for key in containerKeys {
                if let nested = current[key]?.objectValue {
                    pending.append((nested, depth + 1))
                }
            }
        }
        return objects
    }

    /// Date-only values are a fallback for older list responses. The monthly
    /// API may instead repeat its statement date (usually month-end) on every
    /// row, so that pattern is deliberately ignored rather than displayed as
    /// a fabricated ride date.
    static func safeArchiveDateFallbacks(for rides: [JSONValue], expectedMonth: String) -> [Date?] {
        let candidates = rides.map { archiveDateFallback(from: $0) }
        let validDates = candidates.compactMap { $0 }
        guard !validDates.isEmpty else { return candidates }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTimeZone
        let expectedComponents = expectedMonth.count == 6
            ? (year: Int(expectedMonth.prefix(4)), month: Int(expectedMonth.suffix(2)))
            : (year: nil, month: nil)
        let monthMatched = candidates.map { date -> Date? in
            guard let date else { return nil }
            guard let expectedYear = expectedComponents.year, let expectedMonth = expectedComponents.month else {
                return date
            }
            let components = calendar.dateComponents([.year, .month], from: date)
            return components.year == expectedYear && components.month == expectedMonth ? date : nil
        }
        let matchedDates = monthMatched.compactMap { $0 }
        guard !matchedDates.isEmpty else { return Array(repeating: nil, count: rides.count) }

        let distinctDays = Set(matchedDates.map {
            let components = calendar.dateComponents([.year, .month, .day], from: $0)
            return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        })
        // One repeated archive day must not be promoted to every trip's date.
        guard distinctDays.count > 1 else { return Array(repeating: nil, count: rides.count) }
        return monthMatched
    }

    static func archiveDateFallback(from value: JSONValue) -> Date? {
        guard let object = value.objectValue else { return nil }
        return firstDate(["ride_date", "rideDate", "travel_date", "travelDate", "date", "day"], in: object)
    }

    static func hasRepeatedMonthlyStatementDate(_ records: [NinebotRideRecord], expectedMonth: String) -> Bool {
        let dates = records.compactMap(\.startedAt)
        guard dates.count >= 2, dates.count == records.count, expectedMonth.count == 6 else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTimeZone
        guard let expectedYear = Int(expectedMonth.prefix(4)),
              let expectedMonthNumber = Int(expectedMonth.suffix(2)),
              let firstDate = dates.first else {
            return false
        }
        let firstComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: firstDate)
        guard firstComponents.year == expectedYear,
              firstComponents.month == expectedMonthNumber,
              firstComponents.hour == 0,
              firstComponents.minute == 0,
              firstComponents.second == 0,
              let monthStart = calendar.date(from: DateComponents(year: expectedYear, month: expectedMonthNumber, day: 1)),
              let lastDay = calendar.range(of: .day, in: .month, for: monthStart)?.count,
              firstComponents.day == lastDay else {
            return false
        }

        return dates.allSatisfy {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0)
            return components.year == firstComponents.year
                && components.month == firstComponents.month
                && components.day == firstComponents.day
                && components.hour == 0
                && components.minute == 0
                && components.second == 0
        }
    }

    static func firstDurationMinutes(in object: [String: JSONValue], startedAt: Date?, endedAt: Date?) -> Double? {
        let derived = durationMinutes(startedAt: startedAt, endedAt: endedAt)

        if let minutes = firstDurationValue(["durationMinutes", "duration_min", "durationMin"], in: object) {
            return saneDuration(minutes, fallback: derived)
        }
        if let seconds = firstDurationValue(["duration_seconds", "durationSeconds", "ride_seconds", "riding_seconds"], in: object) {
            return saneDuration(seconds / 60, fallback: derived)
        }
        if let value = firstDurationValue(["duration", "ride_time", "rideTime", "riding_time", "ridingTime", "use_time", "useTime", "cost_time", "costTime"], in: object) {
            return saneDuration(ambiguousDurationMinutes(value, derived: derived), fallback: derived)
        }

        return derived
    }

    static func firstBoolLike(_ keys: [String], in object: [String: JSONValue], trueValue: Int) -> Bool? {
        for key in keys {
            if let value = boolLike(object[key], trueValue: trueValue) {
                return value
            }
        }
        return nil
    }

    static func boolLike(_ value: JSONValue?, trueValue: Int) -> Bool? {
        guard let value else { return nil }
        if let intValue = value.intValue {
            return intValue == trueValue
        }
        return value.boolValue
    }

    static func dateValue(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }

        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }

        if let structuredDate = structuredChinaDateValue(string) {
            return structuredDate
        }

        if let number = Double(string) {
            return epochDateValue(number)
        }

        for format in [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ] {
            let formatter = chinaDateFormatter(format: format)
            if let date = formatter.date(from: string) {
                return date
            }
        }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: string) {
            return date
        }

        return nil
    }

    static func date(month: String?, day: Int) -> Date? {
        guard let month, month.count == 6 else { return nil }
        let yearText = String(month.prefix(4))
        let monthText = String(month.suffix(2))
        guard let year = Int(yearText), let monthNumber = Int(monthText) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTimeZone
        return calendar.date(from: DateComponents(year: year, month: monthNumber, day: day))
    }

    static func currentMonthString() -> String {
        monthString(for: Date())
    }

    static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "yyyyMM"
        return formatter.string(from: date)
    }



    static var chinaTimeZone: TimeZone {
        TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
    }

    static func chinaDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    static func structuredChinaDateValue(_ text: String) -> Date? {
        let digitsOnly = text.allSatisfy(\.isNumber)
        guard digitsOnly else { return nil }

        let format: String
        switch text.count {
        case 14:
            format = "yyyyMMddHHmmss"
        case 12:
            format = "yyyyMMddHHmm"
        case 8:
            format = "yyyyMMdd"
        default:
            return nil
        }

        return chinaDateFormatter(format: format).date(from: text)
    }

    static func epochDateValue(_ number: Double) -> Date? {
        if number > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        if number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }

    static func firstDurationValue(_ keys: [String], in object: [String: JSONValue]) -> Double? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let clockDuration = clockDurationMinutes(value) {
                return clockDuration
            }
            if let numericDuration = value.doubleValue, numericDuration > 0 {
                return numericDuration
            }
        }
        return nil
    }

    static func clockDurationMinutes(_ value: JSONValue) -> Double? {
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.contains(":") else {
            return nil
        }

        let parts = string.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        if parts.count == 2 {
            return parts[0] + parts[1] / 60
        }
        return parts[0] * 60 + parts[1] + parts[2] / 60
    }

    static func durationMinutes(startedAt: Date?, endedAt: Date?) -> Double? {
        guard let startedAt, let endedAt else { return nil }
        let minutes = endedAt.timeIntervalSince(startedAt) / 60
        guard minutes > 0, minutes <= 48 * 60 else { return nil }
        return minutes
    }

    static func ambiguousDurationMinutes(_ value: Double, derived: Double?) -> Double {
        guard let derived else {
            return value > 300 ? value / 60 : value
        }

        let minuteCandidate = value
        let secondCandidate = value / 60
        return abs(secondCandidate - derived) < abs(minuteCandidate - derived)
            ? secondCandidate
            : minuteCandidate
    }

    static func saneDuration(_ value: Double, fallback: Double?) -> Double? {
        guard value > 0, value <= 48 * 60 else {
            return fallback
        }
        return value
    }
}
