import SwiftUI
import UIKit
import MapKit
import CoreLocation
import Combine
import AudioToolbox

struct NinebotDashboardView: View {
    @ObservedObject var model: NinebotViewModel
    var onOpenTrips: () -> Void = {}
    @State private var isShowingVehiclePicker = false
    @State private var scrollOffset: CGFloat = 0
    @State private var pullDistance: CGFloat = 0
    @State private var isShowingPullTimestamp = false
    @State private var pullTimestampDismissID = UUID()
    @State private var didTriggerPullRefresh = false
    @State private var isTrackingPullGesture = false
    @State private var pullGestureStartedAtTop = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                dashboardBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let primary = model.dashboard.primaryVehicle {
                            let activeAction = activeVehicleAction(for: primary.vehicle.sn)

                            VehicleControlHero(
                                snapshot: primary,
                                canSwitchVehicle: model.hasVehicles,
                                resolvedAddress: model.resolvedAddressText(for: primary),
                                showsUpdateTime: !model.isAddressGeocodingEnabled,
                                isLoading: model.isLoading,
                                onRingBell: {
                                    performVehicleAction(.bell, sn: primary.vehicle.sn)
                                }
                            ) {
                                isShowingVehiclePicker = true
                            }
                            VehicleActionPanel(
                                snapshot: primary,
                                isLoading: model.isLoading,
                                activeAction: activeAction
                            ) { action in
                                performVehicleAction(action, sn: primary.vehicle.sn)
                            }
                            .padding(.top, primary.state.isCharging == true && !primary.state.isFullyCharged ? -8 : 0)
                            VehicleLocationRideSummaryPanel(
                                snapshot: primary,
                                resolvedAddress: model.resolvedAddressText(for: primary),
                                isLoading: model.isLoading,
                                onOpenTrips: onOpenTrips,
                                onRingBell: {
                                    performVehicleAction(.bell, sn: primary.vehicle.sn)
                                }
                            )
                                .padding(.horizontal, 16)
                            NavigationLink {
                                NinebotBatteryDetailView(
                                    snapshot: primary,
                                    points: model.history(for: primary.vehicle.sn)
                                )
                            } label: {
                                VehicleHealthPanel(snapshot: primary)
                            }
                            .buttonStyle(.plain)
                                .padding(.horizontal, 16)

                            NavigationLink {
                                NinebotVehicleDetailView(model: model, sn: primary.vehicle.sn)
                            } label: {
                                VehicleBasicsPanel(snapshot: primary)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        } else {
                            EmptyDashboardView(
                                hasConfiguration: model.hasConfiguration,
                                isLoading: model.isLoading,
                                onRetry: { Task { await model.refreshDashboard() } }
                            )
                            .padding(.horizontal, 16)
                        }

                        if model.dashboard.vehicles.count > 1 {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("车辆概览")
                                    .font(.headline)
                                    .padding(.horizontal, 16)

                                ForEach(model.dashboard.vehicles) { snapshot in
                                    VehicleRow(
                                        snapshot: snapshot,
                                        isSelected: snapshot.vehicle.sn == (model.dashboard.selectedSN ?? model.dashboard.primaryVehicle?.vehicle.sn)
                                    ) {
                                        model.selectVehicle(sn: snapshot.vehicle.sn)
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, newValue in
                    scrollOffset = max(0, newValue)
                }
                .simultaneousGesture(pullRefreshGesture)

                if let primary = model.dashboard.primaryVehicle, showsRefreshIndicator {
                    PullRefreshTimestampCircle(
                        snapshot: primary,
                        isLoading: isDashboardRefreshLoading,
                        pullDistance: refreshIndicatorDistance,
                        topInset: proxy.safeAreaInsets.top
                    )
                    .zIndex(9)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                if let primary = model.dashboard.primaryVehicle, showsCompactHeader {
                    CompactVehicleHeader(snapshot: primary, topInset: proxy.safeAreaInsets.top)
                        .zIndex(10)
                        .transition(.opacity)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarHidden(true)
        .animation(.easeInOut(duration: 0.18), value: showsCompactHeader)
        .animation(.easeInOut(duration: 0.18), value: showsRefreshIndicator)
        .onAppear {
            if isDashboardRefreshLoading {
                showPullTimestamp(distance: 84, autoDismiss: false)
            }
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if isDashboardRefreshLoading {
                showPullTimestamp(distance: 84, autoDismiss: false)
            } else if !isLoading {
                schedulePullTimestampDismiss()
            }
        }
        .sheet(isPresented: $isShowingVehiclePicker) {
            VehiclePickerSheet(
                dashboard: model.dashboard,
                fallbackAccount: model.currentAccountDisplay
            ) { sn in
                model.selectVehicle(sn: sn)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var showsCompactHeader: Bool {
        scrollOffset > 24
    }

    private func activeVehicleAction(for sn: String) -> NinebotVehicleAction? {
        guard model.activeVehicleActionSN == sn else { return nil }
        return model.activeVehicleAction
    }

    private func performVehicleAction(_ action: NinebotVehicleAction, sn: String) {
        guard !model.isLoading else { return }
        Task {
            await model.perform(action, sn: sn)
        }
    }

    private var isDashboardRefreshLoading: Bool {
        guard model.isLoading else { return false }
        let message = model.loadingMessage ?? ""
        return message.contains("刷新车况") || message.contains("解析车辆位置")
    }

    private var showsRefreshIndicator: Bool {
        isShowingPullTimestamp || isDashboardRefreshLoading
    }

    private var refreshIndicatorDistance: CGFloat {
        isDashboardRefreshLoading ? max(pullDistance, 84) : pullDistance
    }

    private var dashboardBackground: some View {
        Color.teslaPageBackground
    }

    private var pullRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if !isTrackingPullGesture {
                    isTrackingPullGesture = true
                    pullGestureStartedAtTop = scrollOffset <= 1 && value.translation.height > 0
                }

                guard pullGestureStartedAtTop, scrollOffset <= 1, value.translation.height > 0, !model.isLoading else { return }
                let distance = min(value.translation.height, 110)
                pullDistance = distance
                if distance > 16 {
                    showPullTimestamp(distance: distance, autoDismiss: false)
                }
            }
            .onEnded { value in
                defer {
                    isTrackingPullGesture = false
                    pullGestureStartedAtTop = false
                }

                guard pullGestureStartedAtTop, scrollOffset <= 1, value.translation.height > 0 else {
                    schedulePullTimestampDismiss(delay: 200_000_000)
                    return
                }

                if value.translation.height > 86 {
                    triggerPullRefreshIfNeeded()
                } else {
                    schedulePullTimestampDismiss(delay: 220_000_000)
                }
            }
    }

    private func showPullTimestamp(distance: CGFloat, autoDismiss: Bool = true) {
        pullDistance = max(pullDistance, distance)
        isShowingPullTimestamp = true
        if autoDismiss, !model.isLoading {
            schedulePullTimestampDismiss(delay: 1_200_000_000)
        }
    }

    private func triggerPullRefreshIfNeeded() {
        guard !didTriggerPullRefresh, !model.isLoading else { return }
        didTriggerPullRefresh = true
        showPullTimestamp(distance: max(pullDistance, 56), autoDismiss: false)

        Task {
            await model.refreshDashboard()
            didTriggerPullRefresh = false
            schedulePullTimestampDismiss(delay: 450_000_000)
        }
    }

    private func schedulePullTimestampDismiss(delay: UInt64 = 900_000_000) {
        let dismissID = UUID()
        pullTimestampDismissID = dismissID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard pullTimestampDismissID == dismissID, !model.isLoading else { return }
            isShowingPullTimestamp = false
            pullDistance = 0
        }
    }
}

private struct PullRefreshTimestampCircle: View {
    var snapshot: NinebotVehicleSnapshot
    var isLoading: Bool
    var pullDistance: CGFloat
    var topInset: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .overlay {
                    Circle()
                        .stroke(Color.teslaHairline, lineWidth: 1)
                }

            VStack(spacing: 2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.teslaGreen)
                    Text("更新中")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                } else {
                    Text("更新")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                    Text(formatTime(snapshot.state.updatedAt))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 62, height: 62)
        .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 8)
        .scaleEffect(0.86 + min(1, pullDistance / 84) * 0.14)
        .opacity(min(1, max(0.35, pullDistance / 44)))
        .padding(.top, topInset + 6)
    }
}

private struct NinebotVehicleDetailView: View {
    @ObservedObject var model: NinebotViewModel
    var sn: String
    @State private var copiedMessage: String?

    var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VehicleHeroCard(snapshot: snapshot)
                        VehicleDetailPanel(
                            snapshot: snapshot,
                            resolvedAddress: resolvedAddress,
                            isLoading: model.isLoading,
                            onRingBell: {
                                Task { await model.perform(.bell, sn: snapshot.vehicle.sn) }
                            }
                        )
                        VehicleChargingAnalysisPanel(
                            snapshot: snapshot,
                            points: model.history(for: snapshot.vehicle.sn)
                        )
                        RawPayloadCopyPanel(snapshot: snapshot, copiedMessage: $copiedMessage)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("车辆数据已失效")
                        .font(.headline)
                    Text("返回车控页后重新选择车辆")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.teslaPageBackground)
        .navigationTitle("车辆详情")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let copiedMessage {
                Text(copiedMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: copiedMessage)
    }

    private var snapshot: NinebotVehicleSnapshot? {
        model.dashboard.vehicles.first { $0.vehicle.sn == sn } ?? model.dashboard.primaryVehicle
    }

    private var resolvedAddress: String? {
        snapshot.flatMap { model.resolvedAddressText(for: $0) }
    }
}

private struct NinebotBatteryDetailView: View {
    var snapshot: NinebotVehicleSnapshot
    var points: [NinebotVehicleHistoryPoint]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BatteryDetailHeroCard(snapshot: snapshot)
                BatteryDetailMetricsCard(snapshot: snapshot)

                if snapshot.state.isCharging == true || snapshot.state.isFullyCharged {
                    BatteryChargingDetailCard(snapshot: snapshot)
                }

                VehicleChargingAnalysisPanel(snapshot: snapshot, points: points)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("电池")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BatteryDetailHeroCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.state.isFullyCharged ? "已充满" : snapshot.state.chargingStateText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.state.isCharging == true || snapshot.state.isFullyCharged ? Color.teslaGreen : Color.teslaSecondaryText)
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(snapshot.state.batteryText)
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(batteryTextColor(snapshot.state))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text("当前电量")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.teslaSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                BatteryGauge(value: snapshot.state.battery)
                    .frame(width: 72, height: 72)
            }

            BatteryProgressBar(value: snapshot.state.batteryFraction)

            HStack(spacing: 10) {
                BatteryDetailMiniMetric(title: "电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                BatteryDetailMiniMetric(title: "温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
            }
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct BatteryDetailMetricsCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            BasicInfoTile(title: "电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
            BasicInfoTile(title: "温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
            BasicInfoTile(title: "循环次数", value: snapshot.state.batteryCycleCountText, systemImage: "arrow.trianglehead.2.clockwise")
            BasicInfoTile(title: "更新时间", value: formatTime(snapshot.state.updatedAt), systemImage: "clock.fill")
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct BatteryChargingDetailCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(snapshot.state.isFullyCharged ? "充电完成" : "正在充电", systemImage: snapshot.state.isFullyCharged ? "checkmark.circle.fill" : "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(Color.teslaGreen)

                Spacer()

                Text(snapshot.state.estimatedFullChargeTimeText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
            }

            DetailSection(title: "充电信息") {
                DetailRow(title: "充电功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
                DetailRow(title: "充电速度", value: snapshot.state.estimatedChargingSpeedText, systemImage: "bolt.car.fill")
                DetailRow(title: "预计充满", value: snapshot.state.estimatedFullChargeTimeText, systemImage: "timer")
                DetailRow(title: "满电时间", value: snapshot.state.estimatedFullChargeClockText, systemImage: "clock.badge.checkmark.fill")
                DetailRow(title: "充至 80%", value: snapshot.state.estimatedChargeTo80TimeText, systemImage: "battery.75")
                DetailRow(title: "接口剩余", value: snapshot.state.remainingChargeTimeText, systemImage: "clock.badge.questionmark")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct BatteryDetailMiniMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.teslaGreen)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleChargingAnalysisPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var points: [NinebotVehicleHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("充电分析")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(snapshot.state.isCharging == true ? "当前正在充电" : "按本地快照统计")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text(snapshot.state.chargingStateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.state.isCharging == true ? Color.teslaGreen : Color.teslaSecondaryText)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
                BasicInfoTile(title: "温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
                BasicInfoTile(title: "电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                BasicInfoTile(title: "充电速度", value: snapshot.state.estimatedChargingSpeedText, systemImage: "bolt.car.fill")
                BasicInfoTile(title: "充电快照", value: "\(chargingPoints.count) 个", systemImage: "clock.arrow.circlepath")
                BasicInfoTile(title: "电量变化", value: chargingDeltaText, systemImage: "battery.100")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }

    private var chargingPoints: [NinebotVehicleHistoryPoint] {
        points.filter { $0.isCharging == true }.sorted { $0.date < $1.date }
    }

    private var chargingDeltaText: String {
        guard let first = chargingPoints.first?.battery,
              let last = chargingPoints.last?.battery else {
            return "--%"
        }
        let delta = last - first
        return "\(delta >= 0 ? "+" : "")\(delta)%"
    }
}

private struct NinebotVehicleMapView: View {
    var snapshot: NinebotVehicleSnapshot
    var address: String?
    var coordinate: CLLocationCoordinate2D
    var isLoading: Bool
    var onRingBell: () -> Void
    @State private var cameraPosition: MapCameraPosition
    @StateObject private var userLocationProvider = VehicleMapUserLocationProvider()

    init(
        snapshot: NinebotVehicleSnapshot,
        address: String?,
        coordinate: CLLocationCoordinate2D,
        isLoading: Bool,
        onRingBell: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.address = address
        self.coordinate = coordinate
        self.isLoading = isLoading
        self.onRingBell = onRingBell
        _cameraPosition = State(initialValue: .region(Self.region(for: coordinate)))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                Marker(snapshot.vehicle.name, coordinate: coordinate)
                    .tint(Color.teslaGreen)

                if let userCoordinate = userLocationProvider.coordinate {
                    Marker("我的位置", systemImage: "location.fill", coordinate: userCoordinate)
                        .tint(.blue)
                }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.vehicle.name)
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)

                    Text(locationTitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.teslaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ControlMetricPill(title: "纬度", value: formatCoordinate(coordinate.latitude), systemImage: "map")
                    ControlMetricPill(title: "经度", value: formatCoordinate(coordinate.longitude), systemImage: "map.fill")
                }

                if let distanceText = userDistanceText {
                    ControlMetricPill(title: "我的距离", value: distanceText, systemImage: "location.fill")
                }

                HStack(spacing: 10) {
                    Button {
                        onRingBell()
                    } label: {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("寻车鸣笛", systemImage: "bell.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)

                    Button {
                        openInAppleMaps()
                    } label: {
                        Label("Apple 地图", systemImage: "map.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.teslaGreen)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
        }
        .navigationTitle("车辆位置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            userLocationProvider.start()
            fitVisibleRegion()
        }
        .onDisappear {
            userLocationProvider.stop()
        }
        .onChange(of: userLocationProvider.locationVersion) { _, _ in
            fitVisibleRegion()
        }
    }

    private var locationTitle: String {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            return coordinateText(coordinate.latitude, coordinate.longitude)
        }
        return address
    }

    private func openInAppleMaps() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = snapshot.vehicle.name
        mapItem.openInMaps()
    }

    private var userDistanceText: String? {
        guard let userCoordinate = userLocationProvider.coordinate else { return nil }
        let vehicleLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let meters = userLocation.distance(from: vehicleLocation)
        if meters >= 1000 {
            return formatNumber(meters / 1000, unit: " km", maximumFractionDigits: 1)
        }
        return formatNumber(meters, unit: " m", maximumFractionDigits: 0)
    }

    private func fitVisibleRegion() {
        guard let userCoordinate = userLocationProvider.coordinate else {
            cameraPosition = .region(Self.region(for: coordinate))
            return
        }

        cameraPosition = .region(Self.region(for: [coordinate, userCoordinate]))
    }

    private static func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        )
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
        }

        let minLatitude = coordinates.map(\.latitude).min() ?? coordinates[0].latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? coordinates[0].latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? coordinates[0].longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? coordinates[0].longitude
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let latitudeDelta = max((maxLatitude - minLatitude) * 1.8, 0.006)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.8, 0.006)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

@MainActor
private final class VehicleMapUserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var locationVersion = 0

    private let manager = CLLocationManager()

    override init() {
        super.init()
        authorizationStatus = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }

        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if isAuthorized {
                start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last(where: Self.isUsableLocation) else { return }
            coordinate = mapKitCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            locationVersion += 1
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }

    private static func isUsableLocation(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 200
            && (-90...90).contains(location.coordinate.latitude)
            && (-180...180).contains(location.coordinate.longitude)
    }
}

struct NinebotTripsTabView: View {
    @ObservedObject var model: NinebotViewModel

    var body: some View {
        if let snapshot = model.dashboard.primaryVehicle {
            NinebotTripsView(
                model: model,
                snapshot: snapshot,
                recordedRides: model.recordedRides(for: snapshot.vehicle.sn)
            )
        } else {
            EmptyDashboardView(
                hasConfiguration: model.hasConfiguration,
                isLoading: model.isLoading,
                onRetry: { Task { await model.refreshDashboard() } }
            )
            .padding(.horizontal, 16)
                .background(Color.teslaPageBackground.ignoresSafeArea())
                .navigationTitle("行程")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct NinebotTripsView: View {
    @ObservedObject var model: NinebotViewModel
    var snapshot: NinebotVehicleSnapshot
    var recordedRides: [NinebotRecordedRide] = []
    @State private var selectedMonth = tripMonthString(for: Date())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TripHeroPanel(snapshot: snapshot)
                NavigationLink {
                    TripTrendView(snapshot: snapshot, recordedRides: recordedRides)
                } label: {
                    TripTrendEntryCard(snapshot: snapshot)
                }
                .buttonStyle(.plain)
                TripMonthFilterPanel(
                    months: monthOptions,
                    selectedMonth: selectedMonth,
                    nextFetchMonth: nextFetchMonth,
                    isSyncing: model.syncingTravelMonth != nil,
                    onSelect: { selectedMonth = $0 },
                    onFetchOlder: {
                        let targetMonth = nextFetchMonth
                        selectedMonth = targetMonth
                        Task {
                            await model.syncTravelMonth(vehicleSN: snapshot.vehicle.sn, month: targetMonth)
                        }
                    }
                )
                RideListSection(
                    model: model,
                    records: filteredRecords,
                    recordedRides: recordedRides,
                    vehicleSN: snapshot.vehicle.sn,
                    selectedMonth: selectedMonth
                )
            }
            .padding(16)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("行程")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var monthOptions: [String] {
        var months = Set(snapshot.state.rides.compactMap(tripMonthString(for:)))
        months.insert(tripMonthString(for: Date()))
        months.insert(selectedMonth)
        return months.sorted(by: >)
    }

    private var filteredRecords: [NinebotRideRecord] {
        snapshot.state.rides.filter { tripMonthString(for: $0) == selectedMonth }
    }

    private var nextFetchMonth: String {
        previousTripMonth(before: monthOptions.min() ?? selectedMonth)
    }
}

private struct TripMonthFilterPanel: View {
    var months: [String]
    var selectedMonth: String
    var nextFetchMonth: String
    var isSyncing: Bool
    var onSelect: (String) -> Void
    var onFetchOlder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("月份筛选")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("当前 \(tripMonthDisplayName(selectedMonth))")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Button(action: onFetchOlder) {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text("获取 \(tripMonthDisplayName(nextFetchMonth))")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.teslaGreen)
                .disabled(isSyncing)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(months, id: \.self) { month in
                        Button {
                            onSelect(month)
                        } label: {
                            Text(tripMonthDisplayName(month))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(month == selectedMonth ? Color.white : Color.teslaPrimaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(month == selectedMonth ? Color.teslaGreen : Color.teslaCardBackground)
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(month == selectedMonth ? Color.clear : Color.teslaHairline, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(14)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private func tripMonthString(for record: NinebotRideRecord) -> String? {
    guard let date = record.startedAt ?? record.endedAt else { return nil }
    return tripMonthString(for: date)
}

private func tripMonthString(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    formatter.dateFormat = "yyyyMM"
    return formatter.string(from: date)
}

private func previousTripMonth(before month: String) -> String {
    guard month.count == 6,
          let year = Int(month.prefix(4)),
          let monthValue = Int(month.suffix(2)) else {
        return tripMonthString(for: Date())
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let date = calendar.date(from: DateComponents(year: year, month: monthValue, day: 1)) ?? Date()
    let previous = calendar.date(byAdding: .month, value: -1, to: date) ?? date
    return tripMonthString(for: previous)
}

private func tripMonthDisplayName(_ month: String) -> String {
    guard month.count == 6 else { return month }
    let year = month.prefix(4)
    let monthValue = month.suffix(2)
    return "\(year).\(monthValue)"
}

private struct VehiclePickerSheet: View {
    var dashboard: NinebotDashboard
    var fallbackAccount: String
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(accountGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 2)

                            ForEach(group.vehicles) { snapshot in
                                Button {
                                    onSelect(snapshot.vehicle.sn)
                                    dismiss()
                                } label: {
                                    VehiclePickerRow(
                                        snapshot: snapshot,
                                        isSelected: snapshot.vehicle.sn == selectedSN
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.teslaPageBackground)
            .navigationTitle("切换车辆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var selectedSN: String? {
        dashboard.selectedSN ?? dashboard.primaryVehicle?.vehicle.sn
    }

    private var accountGroups: [VehiclePickerAccountGroup] {
        var groups: [VehiclePickerAccountGroup] = []

        for snapshot in dashboard.vehicles {
            let title = vehicleAccountTitle(for: snapshot, fallback: fallbackAccount)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].vehicles.append(snapshot)
            } else {
                groups.append(VehiclePickerAccountGroup(title: title, vehicles: [snapshot]))
            }
        }

        return groups
    }
}

private struct VehiclePickerAccountGroup: Identifiable {
    var title: String
    var vehicles: [NinebotVehicleSnapshot]

    var id: String { title }
}

private func vehicleAccountTitle(for snapshot: NinebotVehicleSnapshot, fallback: String) -> String {
    let keys = [
        "account",
        "account_id",
        "accountId",
        "phone",
        "mobile",
        "user_phone",
        "userPhone",
        "owner_phone",
        "ownerPhone",
        "bind_phone",
        "bindPhone",
        "user_id",
        "userId",
        "business_uid",
        "businessUID",
        "uid",
        "uuid"
    ]

    if let raw = snapshot.vehicle.raw {
        for key in keys {
            if let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return "\(value) 账号"
            }
        }
    }

    let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallback.isEmpty, fallback != "未绑定账号" {
        return "\(fallback) 账号"
    }
    return "当前代理账号"
}

private struct VehiclePickerRow: View {
    var snapshot: NinebotVehicleSnapshot
    var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 52)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.vehicle.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(snapshot.state.batteryText)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(batteryTextColor(snapshot.state))
                }

                Text(snapshot.vehicle.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(snapshot.vehicle.identifierSummaryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Label(snapshot.state.primaryStatusText, systemImage: statusSystemImage(snapshot.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(snapshot.state))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.teslaGreen : Color(.tertiaryLabel))
                .padding(.top, 2)
        }
        .padding(12)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}

private struct CompactVehicleHeader: View {
    var snapshot: NinebotVehicleSnapshot
    var topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.teslaPageBackground
                .frame(height: topInset)
            Text("\(snapshot.vehicle.name)·\(snapshot.state.batteryText)·\(compactVehicleStatusText(snapshot.state))")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .padding(.horizontal, 16)
                .background(Color.teslaPageBackground)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

private struct VehicleControlHero: View {
    var snapshot: NinebotVehicleSnapshot
    var canSwitchVehicle: Bool
    var resolvedAddress: String?
    var showsUpdateTime: Bool
    var isLoading: Bool
    var onRingBell: () -> Void
    var onSwitchVehicle: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        guard canSwitchVehicle else { return }
                        onSwitchVehicle()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .center, spacing: 6) {
                                Text(snapshot.vehicle.name)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Color.teslaPrimaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                if canSwitchVehicle {
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.teslaSecondaryText)
                                }
                            }

                            Text(snapshot.vehicle.model)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(canSwitchVehicle ? "切换车辆" : snapshot.vehicle.name)

                    if let resolvedAddress = normalizedResolvedAddress {
                        if let coordinate = vehicleCoordinate(snapshot.state) {
                            NavigationLink {
                                NinebotVehicleMapView(
                                    snapshot: snapshot,
                                    address: resolvedAddress,
                                    coordinate: coordinate,
                                    isLoading: isLoading,
                                    onRingBell: onRingBell
                                )
                            } label: {
                                Text(resolvedAddress)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.teslaSecondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(resolvedAddress)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else if showsUpdateTime {
                        Text("更新 \(formatDate(snapshot.state.updatedAt))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.teslaSecondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                StatusChip(
                    title: compactVehicleStatusText(snapshot.state),
                    systemImage: statusSystemImage(snapshot.state),
                    color: statusColor(snapshot.state)
                )
            }

            VehicleRangeHeroCard(rangeText: snapshot.state.localEstimatedMileageText)

            VehicleMotionScene(snapshot: snapshot)
                .frame(maxWidth: .infinity)
                .frame(height: 336)

            VStack(spacing: 12) {
                BatteryProgressBar(value: snapshot.state.batteryFraction)

                HStack(spacing: 10) {
                    TeslaHeroMetric(title: "电量", value: snapshot.state.batteryText, systemImage: "battery.100")
                    Divider()
                        .frame(height: 34)
                    TeslaHeroMetric(title: "接口续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
                    Divider()
                        .frame(height: 34)
                    TeslaHeroMetric(title: "最高速度", value: snapshot.state.maximumSpeedText, systemImage: "speedometer")
                }
            }

        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var normalizedResolvedAddress: String? {
        guard let value = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct VehicleRangeHeroCard: View {
    var rangeText: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "road.lanes")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.teslaGreen)
                .frame(width: 38, height: 38)
                .background(Color.teslaGreen.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("预计可行驶")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                Text(rangeText)
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Color.teslaCardBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("预计可行驶 \(rangeText)")
    }
}

private enum VehicleMotionSceneMode: Equatable {
    case parked
    case riding
    case charging
}

/// 主页车辆动态场景。
///
/// v1.2.62 重构主页时只保留了静态 VehicleImage，导致旧版的道路、车辆和充电画面消失。
/// 这里保留当前版本的数据和登录结构，仅恢复一个不依赖额外网络请求的本地场景，确保深色模式、离线和图片接口异常时仍然有稳定画面。
private enum RideWeatherCondition: String, Codable, Equatable {
    case clear
    case partlyCloudy
    case cloudy
    case rain
    case storm
    case snow
    case fog

    var title: String {
        switch self {
        case .clear: return "晴"
        case .partlyCloudy: return "多云"
        case .cloudy: return "阴天"
        case .rain: return "下雨"
        case .storm: return "雷雨"
        case .snow: return "下雪"
        case .fog: return "雾"
        }
    }

    var systemImage: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .rain: return "cloud.heavyrain.fill"
        case .storm: return "cloud.bolt.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .fog: return "cloud.fog.fill"
        }
    }

    var isWet: Bool { self == .rain || self == .storm }
}

private struct RideWeatherSnapshot: Equatable {
    var condition: RideWeatherCondition
    var temperatureC: Double?
    var windSpeedKmh: Double?
    var ultravioletIndex: Double?
    var airQualityIndex: Double?
    var fetchedAt: Date

    /// The scene uses the device clock instead of a value frozen at the last
    /// weather request. This lets the primary card switch immediately between
    /// the day and night scene even when the vehicle is parked for hours or
    /// the weather service is temporarily unavailable.
    var isDay: Bool {
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: Date())
        return (7...18).contains(hour)
    }

    static var fallback: RideWeatherSnapshot {
        RideWeatherSnapshot(
            condition: .partlyCloudy,
            temperatureC: nil,
            windSpeedKmh: nil,
            ultravioletIndex: nil,
            airQualityIndex: nil,
            fetchedAt: Date()
        )
    }
}

private final class RideWeatherProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot = RideWeatherSnapshot.fallback

    private let locationManager = CLLocationManager()
    private var latestPhoneLocation: CLLocation?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastFetchedAt: Date?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refresh(vehicleLatitude: Double?, vehicleLongitude: Double?) async {
        let coordinate: CLLocationCoordinate2D?
        if let vehicleLatitude, let vehicleLongitude,
           abs(vehicleLatitude) <= 90, abs(vehicleLongitude) <= 180 {
            coordinate = CLLocationCoordinate2D(latitude: vehicleLatitude, longitude: vehicleLongitude)
        } else {
            coordinate = await requestPhoneCoordinate()
        }

        guard let coordinate else {
            await MainActor.run { self.snapshot = .fallback }
            return
        }

        if let lastCoordinate,
           let lastFetchedAt,
           Date().timeIntervalSince(lastFetchedAt) < 300,
           abs(lastCoordinate.latitude - coordinate.latitude) < 0.02,
           abs(lastCoordinate.longitude - coordinate.longitude) < 0.02 {
            return
        }

        do {
            let weather = try await fetchWeather(coordinate: coordinate)
            await MainActor.run {
                self.snapshot = weather
                self.lastCoordinate = coordinate
                self.lastFetchedAt = Date()
            }
        } catch {
            // Keep the last successful weather instead of blanking the scene while offline.
            await MainActor.run {
                if self.lastFetchedAt == nil { self.snapshot = .fallback }
            }
        }
    }

    private func requestPhoneCoordinate() async -> CLLocationCoordinate2D? {
        if let latestPhoneLocation { return latestPhoneLocation.coordinate }
        guard CLLocationManager.locationServicesEnabled() else { return nil }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            return nil
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }.map(\.coordinate)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if locationContinuation != nil { manager.requestLocation() }
        case .denied, .restricted:
            locationContinuation?.resume(returning: nil)
            locationContinuation = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestPhoneLocation = locations.last
        locationContinuation?.resume(returning: locations.last)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(returning: nil)
        locationContinuation = nil
    }

    private func fetchWeather(coordinate: CLLocationCoordinate2D) async throws -> RideWeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.5f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.5f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m,uv_index"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(OpenMeteoWeatherResponse.self, from: data)
        let current = payload.current
        return RideWeatherSnapshot(
            condition: RideWeatherCondition(code: current.weatherCode),
            temperatureC: current.temperature,
            windSpeedKmh: current.windSpeed,
            ultravioletIndex: current.uvIndex,
            airQualityIndex: await fetchAirQuality(coordinate: coordinate),
            fetchedAt: Date()
        )
    }

    private func fetchAirQuality(coordinate: CLLocationCoordinate2D) async -> Double? {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.5f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.5f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "us_aqi"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components.url else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let payload = try? JSONDecoder().decode(OpenMeteoAirQualityResponse.self, from: data) else {
            return nil
        }
        return payload.current.usAqi
    }
}

private struct OpenMeteoAirQualityResponse: Decodable {
    var current: Current

    struct Current: Decodable {
        var usAqi: Double?

        enum CodingKeys: String, CodingKey {
            case usAqi = "us_aqi"
        }
    }
}

private struct OpenMeteoWeatherResponse: Decodable {
    var current: Current

    struct Current: Decodable {
        var temperature: Double?
        var weatherCode: Int?
        var windSpeed: Double?
        var uvIndex: Double?

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
            case uvIndex = "uv_index"
        }
    }
}

private extension RideWeatherCondition {
    init(code: Int?) {
        switch code ?? -1 {
        case 0: self = .clear
        case 1...3: self = code == 1 ? .partlyCloudy : .cloudy
        case 45, 48: self = .fog
        case 51...67, 80...82: self = .rain
        case 71...77, 85...86: self = .snow
        case 95...99: self = .storm
        default: self = .partlyCloudy
        }
    }
}


private struct WeatherCloudLayer: View {
    var size: CGSize
    var phase: TimeInterval
    var dense: Bool

    var body: some View {
        HStack(spacing: size.width * 0.04) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: -size.width * 0.035) {
                    Circle().fill(.white.opacity(dense ? 0.22 : 0.16)).frame(width: size.width * 0.16)
                    Circle().fill(.white.opacity(dense ? 0.28 : 0.20)).frame(width: size.width * 0.22)
                    Circle().fill(.white.opacity(dense ? 0.18 : 0.14)).frame(width: size.width * 0.13)
                }
                .offset(x: CGFloat(sin(phase * 0.12 + Double(index))) * 8, y: CGFloat(index % 2) * 12)
            }
        }
        .blur(radius: 2)
        .offset(x: -size.width * 0.12, y: -size.height * 0.27)
        .allowsHitTesting(false)
    }
}

private struct WeatherRainLayer: View {
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        ForEach(0..<22, id: \.self) { index in
            let progress = (phase * 0.65 + Double(index) * 0.077).truncatingRemainder(dividingBy: 1)
            Capsule()
                .fill(.white.opacity(0.16 + Double(index % 3) * 0.05))
                .frame(width: 1.2, height: size.height * (0.035 + CGFloat(index % 4) * 0.008))
                .rotationEffect(.degrees(12))
                .offset(
                    x: size.width * (-0.48 + CGFloat(index % 11) * 0.095),
                    y: size.height * (-0.28 + CGFloat(progress) * 0.76)
                )
        }
        .allowsHitTesting(false)
    }
}
private struct RideWeatherCard: View {
    var snapshot: RideWeatherSnapshot
    var width: CGFloat = 126

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: snapshot.condition.systemImage)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: snapshot.condition.isWet ? 24 : 17, weight: .semibold))
                    .foregroundStyle(snapshot.condition.isWet ? Color.cyan : Color.white)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    Text("实时天气")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.64))
                    Text(snapshot.condition.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 3)

                if !snapshot.condition.isWet {
                    Image(systemName: snapshot.isDay ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(snapshot.isDay ? Color.yellow : Color.orange.opacity(0.9))
                }
            }

            HStack(spacing: 6) {
                weatherPill("thermometer.medium", snapshot.temperatureC.map { "\(Int($0.rounded()))°" } ?? "--")
                weatherPill("wind", snapshot.windSpeedKmh.map { String(format: "%.0f", $0) } ?? "--")
            }

            HStack(spacing: 4) {
                Image(systemName: "aqi.medium")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(aqiColor(snapshot.airQualityIndex))
                Text("空气 \(snapshot.airQualityIndex.map { "\(aqiLabel($0)) \(Int($0.rounded()))" } ?? "--")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(width: width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("天气 \(snapshot.condition.title)，气温 \(snapshot.temperatureC.map { String(format: "%.0f", $0) } ?? "未知") 度，风速 \(snapshot.windSpeedKmh.map { String(format: "%.0f", $0) } ?? "未知") 公里每小时，空气质量 \(snapshot.airQualityIndex.map { String(format: "%.0f", $0) } ?? "未知")")
    }

    private func weatherPill(_ image: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: image)
                .font(.system(size: 10, weight: .semibold))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(0.10), in: Capsule())
    }
}

private func aqiLabel(_ value: Double) -> String {
    switch value {
    case ..<51: return "优"
    case ..<101: return "良"
    case ..<151: return "轻度"
    case ..<201: return "中度"
    case ..<301: return "重度"
    default: return "严重"
    }
}

private func aqiColor(_ value: Double?) -> Color {
    guard let value else { return .white.opacity(0.75) }
    switch value {
    case ..<51: return Color.green
    case ..<101: return Color.yellow
    case ..<151: return Color.orange
    default: return Color.red.opacity(0.88)
    }
}

private struct VehicleMotionScene: View {
    var snapshot: NinebotVehicleSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var weatherProvider = RideWeatherProvider()
    @State private var chargingStartPulse: Double = 0

    private var mode: VehicleMotionSceneMode {
        if snapshot.state.isCharging == true { return .charging }
        if let rawStatus = snapshot.state.rawStatus {
            let movementKeys = ["isRiding", "riding", "isMoving", "moving", "inMotion", "driving"]
            if movementKeys.contains(where: { rawStatus[$0]?.boolValue == true }) { return .riding }
        }
        if snapshot.state.isPoweredOn == true && snapshot.state.isLocked != true { return .riding }
        return .parked
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if reduceMotion {
                    scene(size: proxy.size, phase: 0)
                } else {
                    // 15 fps is enough for cable current and keeps the home screen
                    // responsive on older iPhones. Static layers are not rebuilt at 30 fps.
                    TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                        scene(size: proxy.size, phase: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task(id: weatherLocationKey) {
            await weatherProvider.refresh(vehicleLatitude: snapshot.state.latitude, vehicleLongitude: snapshot.state.longitude)
        }
        .onChange(of: mode) { oldMode, newMode in
            guard oldMode != .charging, newMode == .charging else { return }
            triggerChargingStartFeedback()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sceneAccessibilityLabel)
    }

    @ViewBuilder
    private func scene(size: CGSize, phase: TimeInterval) -> some View {
        switch mode {
        case .parked:
            VehicleParkedScene(snapshot: snapshot, weather: weatherProvider.snapshot, size: size, phase: phase)
        case .riding:
            VehicleRidingScene(snapshot: snapshot, weather: weatherProvider.snapshot, size: size, phase: phase)
        case .charging:
            VehicleChargingScene(snapshot: snapshot, weather: weatherProvider.snapshot, size: size, phase: phase, startPulse: chargingStartPulse)
        }
    }

    private func triggerChargingStartFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
        AudioServicesPlaySystemSound(1104)

        chargingStartPulse = 0
        withAnimation(.easeOut(duration: 0.85)) {
            chargingStartPulse = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 950_000_000)
            chargingStartPulse = 0
        }
    }

    private var weatherLocationKey: String {
        if let latitude = snapshot.state.latitude, let longitude = snapshot.state.longitude {
            return "vehicle-\(latitude)-\(longitude)"
        }
        return "phone-location"
    }

    private var sceneAccessibilityLabel: String {
        switch mode {
        case .parked: return snapshot.state.isPoweredOn == true ? "车辆已停稳，已上电" : "车辆已停稳"
        case .riding: return "车辆骑行中，实时车辆数据已更新"
        case .charging: return "车辆充电中，电量 \(snapshot.state.batteryText)，充电功率 \(snapshot.state.chargingPowerText)"
        }
    }
}

private enum VehicleSceneBackdropStyle: Equatable {
    case parked
    case riding
    case charging
}

private struct VehicleSceneBackdrop: View {
    var size: CGSize
    var phase: TimeInterval
    var style: VehicleSceneBackdropStyle
    var weather: RideWeatherSnapshot

    var body: some View {
        ZStack {
            if style == .charging {
                ChargingGarageBackdrop(isDay: weather.isDay, size: size)
            } else {
                UrbanPhotoBackdrop(isDay: weather.isDay, condition: weather.condition, style: style, size: size, phase: phase)
                RoadPerspectiveLayer(size: size, phase: phase, animates: style == .riding)
                UrbanStreetLamp(size: size, isDay: weather.isDay)
            }

            if !weather.isDay && style != .charging { NightAtmosphere(size: size, phase: phase) }
            if weather.condition.isWet { RainLayer(size: size, phase: phase) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private struct UrbanPhotoBackdrop: View {
    var isDay: Bool
    var condition: RideWeatherCondition
    var style: VehicleSceneBackdropStyle
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: skyColors,
                startPoint: .top,
                endPoint: .bottom
            )

            // Cloud coverage is intentionally tied to the exact “多云” condition.
            // Overcast and wet weather use a muted sky/rain layer instead.
            if condition == .partlyCloudy {
                CloudBank(size: size, phase: phase, isDay: isDay)
                    .opacity(isDay ? 0.42 : 0.24)
            }

            CityHorizonGlow(size: size, isDay: isDay)
            ModernCitySkyline(size: size, isDay: isDay, isRiding: style == .riding, phase: phase)
                .offset(y: -size.height * 0.03)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(isDay ? 0.16 : 0.52)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: size.height * 0.46)
        }
    }

    private var skyColors: [Color] {
        if isDay {
            switch condition {
            case .cloudy, .fog:
                return [Color(red: 0.48, green: 0.55, blue: 0.61), Color(red: 0.65, green: 0.69, blue: 0.70), Color(red: 0.31, green: 0.36, blue: 0.38)]
            case .rain, .storm:
                return [Color(red: 0.22, green: 0.30, blue: 0.38), Color(red: 0.38, green: 0.45, blue: 0.49), Color(red: 0.23, green: 0.28, blue: 0.30)]
            default:
                return [Color(red: 0.31, green: 0.55, blue: 0.77), Color(red: 0.68, green: 0.78, blue: 0.82), Color(red: 0.28, green: 0.35, blue: 0.38)]
            }
        }
        return [Color(red: 0.004, green: 0.012, blue: 0.035), Color(red: 0.015, green: 0.055, blue: 0.115), Color(red: 0.055, green: 0.095, blue: 0.130)]
    }
}

/// A deliberately sparse office skyline. Six towers with different silhouettes
/// read as a real business district while leaving negative space around the car.
private struct ModernCitySkyline: View {
    private struct Tower: Identifiable {
        let id: Int
        let x: CGFloat
        let width: CGFloat
        let height: CGFloat
        let windowColumns: Int
        let windowRows: Int
        let crown: ModernOfficeTower.Crown
    }

    var size: CGSize
    var isDay: Bool
    var isRiding: Bool
    var phase: TimeInterval

    private let towers: [Tower] = [
        Tower(id: 0, x: 0.08, width: 0.13, height: 0.23, windowColumns: 3, windowRows: 5, crown: .flat),
        Tower(id: 1, x: 0.24, width: 0.17, height: 0.35, windowColumns: 4, windowRows: 8, crown: .stepped),
        Tower(id: 2, x: 0.43, width: 0.15, height: 0.27, windowColumns: 3, windowRows: 6, crown: .sloped),
        Tower(id: 3, x: 0.61, width: 0.20, height: 0.43, windowColumns: 5, windowRows: 10, crown: .flat),
        Tower(id: 4, x: 0.80, width: 0.14, height: 0.30, windowColumns: 3, windowRows: 7, crown: .antenna),
        Tower(id: 5, x: 0.94, width: 0.10, height: 0.20, windowColumns: 2, windowRows: 4, crown: .sloped)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(towers) { tower in
                let towerHeight = size.height * tower.height
                ModernOfficeTower(
                    index: tower.id,
                    isDay: isDay,
                    width: size.width * tower.width,
                    height: towerHeight,
                    windowColumns: tower.windowColumns,
                    windowRows: tower.windowRows,
                    crown: tower.crown
                )
                .position(
                    x: size.width * tower.x,
                    y: size.height * 0.70 - towerHeight / 2
                )
            }
        }
        // The parallax is kept below one point: the scene reads as motion without
        // smearing the window detail or competing with the live vehicle data.
        .offset(x: isRiding ? CGFloat(sin(phase * 0.35)) * 0.8 : 0)
        .allowsHitTesting(false)
    }
}

private struct ModernOfficeTower: View {
    enum Crown {
        case flat
        case stepped
        case sloped
        case antenna
    }

    var index: Int
    var isDay: Bool
    var width: CGFloat
    var height: CGFloat
    var windowColumns: Int
    var windowRows: Int
    var crown: Crown

    var body: some View {
        VStack(spacing: 0) {
            crownView
                .frame(height: crown == .flat ? 2 : max(7, height * 0.055))

            RoundedRectangle(cornerRadius: min(5, width * 0.08), style: .continuous)
                .fill(facade)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(isDay ? 0.12 : 0.035))
                        .frame(width: max(2, width * 0.08))
                }
                .overlay {
                    WindowGrid(
                        index: index,
                        isDay: isDay,
                        columns: windowColumns,
                        rows: windowRows,
                        width: width,
                        height: height
                    )
                    .padding(.horizontal, max(5, width * 0.12))
                    .padding(.vertical, max(8, height * 0.065))
                }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: min(5, width * 0.08), style: .continuous))
        .shadow(color: .black.opacity(isDay ? 0.14 : 0.46), radius: 8, x: 0, y: 5)
    }

    @ViewBuilder
    private var crownView: some View {
        switch crown {
        case .flat:
            Color.clear
        case .stepped:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(facade.opacity(0.93))
                .frame(width: width * 0.62)
        case .sloped:
            Triangle()
                .fill(facade.opacity(0.96))
                .frame(width: width * 0.72)
        case .antenna:
            VStack(spacing: 0) {
                Capsule().fill(.white.opacity(isDay ? 0.45 : 0.75)).frame(width: 1.5, height: max(5, height * 0.035))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(facade.opacity(0.96))
                    .frame(width: width * 0.48, height: max(3, height * 0.018))
            }
        }
    }

    private var facade: LinearGradient {
        LinearGradient(
            colors: isDay
                ? [Color(red: 0.28, green: 0.40, blue: 0.48), Color(red: 0.12, green: 0.19, blue: 0.25)]
                : [Color(red: 0.018, green: 0.040, blue: 0.075), Color(red: 0.004, green: 0.011, blue: 0.027)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct WindowGrid: View {
    var index: Int
    var isDay: Bool
    var columns: Int
    var rows: Int
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let columnSpacing = max(2, width * 0.045)
            let windowWidth = max(1.5, (proxy.size.width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
            let rowSpacing = max(2.5, height * 0.014)

            VStack(spacing: rowSpacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: columnSpacing) {
                        ForEach(0..<columns, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                                .fill(windowColor(row: row, column: column))
                                .frame(width: windowWidth, height: max(1.5, height * 0.010))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func windowColor(row: Int, column: Int) -> Color {
        let pattern = (row * 7 + column * 3 + index * 5) % 9
        if isDay {
            return pattern == 0 ? Color.white.opacity(0.62) : Color(red: 0.57, green: 0.78, blue: 0.89).opacity(0.32)
        }
        return pattern == 0 || pattern == 4 ? Color(red: 1.0, green: 0.69, blue: 0.34).opacity(0.92) : Color(red: 0.33, green: 0.56, blue: 0.82).opacity(0.22)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CityHorizonGlow: View {
    var size: CGSize
    var isDay: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(isDay ? Color.white.opacity(0.13) : Color.blue.opacity(0.08)).frame(height: 1)
            Rectangle().fill(isDay ? Color(red: 0.19, green: 0.33, blue: 0.39).opacity(0.18) : Color.blue.opacity(0.16)).frame(height: size.height * 0.065)
            Rectangle().fill(Color.black.opacity(isDay ? 0.10 : 0.28)).frame(height: size.height * 0.025)
        }
        .frame(maxWidth: .infinity)
        .offset(y: -size.height * 0.285)
    }
}

private struct CloudBank: View {
    var size: CGSize
    var phase: TimeInterval
    var isDay: Bool

    var body: some View {
        HStack(spacing: -size.width * 0.06) {
            ForEach(0..<5, id: \.self) { index in
                Ellipse()
                    .fill(isDay ? Color.white.opacity(0.16) : Color.white.opacity(0.05))
                    .frame(width: size.width * (0.18 + CGFloat(index % 2) * 0.08), height: size.height * (0.08 + CGFloat(index % 3) * 0.018))
                    .blur(radius: 10)
            }
        }
        .offset(x: CGFloat(sin(phase * 0.08)) * 14, y: -size.height * 0.68)
    }
}

private struct NightAtmosphere: View {
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.20 + Double(index % 3) * 0.08))
                    .frame(width: index % 4 == 0 ? 2.4 : 1.3, height: index % 4 == 0 ? 2.4 : 1.3)
                    .position(x: size.width * (0.04 + CGFloat((index * 17) % 92) / 100), y: size.height * (0.06 + CGFloat((index * 13) % 40) / 100))
            }
            Circle()
                .fill(Color.orange.opacity(0.30))
                .frame(width: size.height * 0.11)
                .blur(radius: 13)
                .offset(x: size.width * 0.34, y: -size.height * 0.34)
            Circle()
                .fill(Color(red: 0.90, green: 0.93, blue: 0.98).opacity(0.88))
                .frame(width: size.height * 0.075)
                .offset(x: size.width * 0.34, y: -size.height * 0.34)
                .scaleEffect(1 + CGFloat(sin(phase * 0.18)) * 0.02)
        }
        .allowsHitTesting(false)
    }
}

private struct UrbanStreetLamp: View {
    var size: CGSize
    var isDay: Bool

    var body: some View {
        let poleX = size.width * 0.88
        let lampX = size.width * 0.80
        let lampY = size.height * 0.43

        ZStack {
            if !isDay {
                Circle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: size.width * 0.19, height: size.height * 0.19)
                    .blur(radius: 15)
                    .position(x: lampX, y: lampY + 6)
                Circle()
                    .fill(Color.yellow.opacity(0.16))
                    .frame(width: size.width * 0.10, height: size.height * 0.11)
                    .blur(radius: 6)
                    .position(x: lampX, y: lampY + 4)
            }

            Capsule()
                .fill(LinearGradient(colors: [.black.opacity(0.84), .white.opacity(isDay ? 0.20 : 0.12), .black.opacity(0.82)], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(3, size.width * 0.009), height: size.height * 0.38)
                .position(x: poleX, y: size.height * 0.61)

            Capsule()
                .fill(Color.black.opacity(0.82))
                .frame(width: size.width * 0.105, height: max(3, size.height * 0.010))
                .position(x: (poleX + lampX) / 2, y: lampY - 2)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isDay ? Color(red: 0.17, green: 0.20, blue: 0.21) : Color(red: 1.0, green: 0.72, blue: 0.31))
                .frame(width: size.width * 0.052, height: max(6, size.height * 0.020))
                .shadow(color: isDay ? .clear : Color.orange.opacity(0.95), radius: 7)
                .position(x: lampX, y: lampY + 2)
        }
        .allowsHitTesting(false)
    }
}

private struct RoadPerspectiveLayer: View {
    var size: CGSize
    var phase: TimeInterval
    var animates: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [Color(red: 0.06, green: 0.075, blue: 0.09), Color.black.opacity(0.96)], startPoint: .top, endPoint: .bottom))
                .frame(height: size.height * 0.38)
                .offset(y: size.height * 0.67)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .offset(y: size.height * 0.67)

            ForEach(0..<3, id: \.self) { row in
                ForEach(0..<6, id: \.self) { column in
                    PerspectiveDash(size: size, phase: phase, animates: animates, row: row, column: column)
                }
            }

            if animates {
                ForEach(0..<8, id: \.self) { index in
                    MotionStreak(size: size, phase: phase, index: index)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PerspectiveDash: View {
    var size: CGSize
    var phase: TimeInterval
    var animates: Bool
    var row: Int
    var column: Int

    var body: some View {
        let dashWidth = size.width * (0.060 + CGFloat(row) * 0.022)
        let gap = size.width * (0.15 + CGFloat(row) * 0.025)
        let trackWidth = dashWidth + gap
        // TranslateX-equivalent, repeated by exactly one segment pitch so the
        // road markings return to the same visual arrangement without a jump.
        let scroll = animates
            ? CGFloat((phase * 36).truncatingRemainder(dividingBy: Double(trackWidth)))
            : 0
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white.opacity(0.80 - Double(row) * 0.08))
            .frame(width: dashWidth, height: max(3, size.height * (0.008 + CGFloat(row) * 0.003)))
            .position(
                x: -trackWidth + CGFloat(column) * trackWidth + scroll,
                y: size.height * (0.75 + CGFloat(row) * 0.09)
            )
    }
}

private struct MotionStreak: View {
    var size: CGSize
    var phase: TimeInterval
    var index: Int

    var body: some View {
        let widthFactor: CGFloat = 0.04 + CGFloat(index % 4) * 0.018
        let width: CGFloat = size.width * widthFactor
        let opacity: Double = 0.09 + Double(index % 3) * 0.04
        let normalizedIndex: CGFloat = CGFloat((index * 49) % 120) / 100.0
        let phaseOffset: CGFloat = CGFloat((phase * 44).truncatingRemainder(dividingBy: 80))
        let x: CGFloat = -size.width * 0.45 + normalizedIndex * size.width + phaseOffset
        let y: CGFloat = size.height * (0.59 + CGFloat(index % 4) * 0.06)
        return Capsule()
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: 2)
            .offset(x: x, y: y)
    }
}

private struct RainLayer: View {
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        ForEach(0..<26, id: \.self) { index in
            let progress = (phase * 0.72 + Double(index) * 0.17).truncatingRemainder(dividingBy: 1)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: size.height * 0.035)
                .rotationEffect(.degrees(14))
                .position(x: size.width * (0.02 + CGFloat((index * 29) % 96) / 100), y: -size.height * 0.05 + size.height * CGFloat(progress) * 0.8)
        }
        .allowsHitTesting(false)
    }
}

private struct VehicleGlassCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.17), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleSceneHeader: View {
    var title: String
    var subtitle: String?
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: tint.opacity(0.9), radius: 7)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.67))
            }
            Capsule()
                .fill(tint)
                .frame(width: 42, height: 4)
                .shadow(color: tint.opacity(0.55), radius: 5)
        }
    }
}

private struct VehicleParkedScene: View {
    var snapshot: NinebotVehicleSnapshot
    var weather: RideWeatherSnapshot
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        ZStack(alignment: .topLeading) {
            VehicleSceneBackdrop(size: size, phase: phase, style: .parked, weather: weather)

            VehicleSceneHeader(
                title: snapshot.state.isPoweredOn == true ? "车辆已停稳" : "车辆已停稳",
                subtitle: snapshot.state.isPoweredOn == true ? "已上电 · 车辆状态正常" : "已锁定 · 等待下一次刷新",
                tint: snapshot.state.isPoweredOn == true ? Color.teslaGreen : .white
            )
            .padding(.leading, 20)
            .padding(.top, 22)

            RideWeatherCard(snapshot: weather, width: min(size.width * 0.36, 132))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 17)
                .padding(.trailing, 15)

            Ellipse()
                .fill(Color.black.opacity(0.38))
                .frame(width: size.width * 0.56, height: size.height * 0.065)
                .blur(radius: 9)
                .offset(x: size.width * 0.12, y: size.height * 0.82)

            VehicleImage(urlString: snapshot.vehicle.imageURLString, sn: snapshot.vehicle.sn, size: min(size.width * 0.76, 285), showsBackground: false)
                .shadow(color: .black.opacity(0.42), radius: 15, x: 0, y: 10)
                .position(x: size.width * 0.50, y: size.height * 0.70)

        }
        .frame(width: size.width, height: size.height)
    }
}

private struct RidingWindLayer: View {
    var size: CGSize
    var phase: TimeInterval
    var windSpeedKmh: Double?

    private var intensity: CGFloat {
        min(max(CGFloat(windSpeedKmh ?? 18) / 42, 0.45), 1)
    }

    var body: some View {
        ForEach(0..<12, id: \.self) { index in
            let progress = (phase * (0.38 + Double(index % 3) * 0.06) + Double(index) * 0.137)
                .truncatingRemainder(dividingBy: 1)
            let length = size.width * (0.075 + CGFloat(index % 4) * 0.022) * intensity
            let y = size.height * (0.24 + CGFloat((index * 37) % 62) / 100)

            Capsule()
                .fill(.white.opacity(0.10 + Double(index % 3) * 0.045))
                .frame(width: length, height: index.isMultiple(of: 3) ? 1.5 : 1)
                .rotationEffect(.degrees(-7))
                .offset(
                    x: size.width * (-0.58 + CGFloat(progress) * 1.28),
                    y: y
                )
        }
        .blur(radius: 0.15)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct VehicleRidingScene: View {
    var snapshot: NinebotVehicleSnapshot
    var weather: RideWeatherSnapshot
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        // State indication rather than decoration: small transform-only motion
        // makes a moving vehicle legible without disturbing readable data.
        let bob = CGFloat(sin(phase * 6.2)) * 1.5
        let drift = CGFloat(sin(phase * 1.7)) * 2.0

        return ZStack(alignment: .topLeading) {
            VehicleSceneBackdrop(size: size, phase: phase, style: .riding, weather: weather)

            VehicleSceneHeader(title: "骑行中", subtitle: "实时车辆数据", tint: Color.teslaGreen)
                .padding(.leading, 20)
                .padding(.top, 18)

            RidingWindLayer(size: size, phase: phase, windSpeedKmh: weather.windSpeedKmh)
                .padding(.top, size.height * 0.06)

            // Keep live weather visible without competing with the riding state.
            RideWeatherCard(snapshot: weather, width: min(size.width * 0.37, 132))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 17)
                .padding(.trailing, 14)

            Ellipse()
                .fill(Color.black.opacity(0.42))
                .frame(width: size.width * 0.55, height: size.height * 0.065)
                .blur(radius: 8)
                .offset(x: size.width * 0.23, y: size.height * 0.83)

            VehicleImage(
                urlString: snapshot.vehicle.imageURLString,
                sn: snapshot.vehicle.sn,
                size: min(size.width * 0.69, 278),
                showsBackground: false
            )
            .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 10)
            .offset(x: size.width * 0.17 + drift, y: size.height * 0.28 + bob)
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct VehicleChargingScene: View {
    var snapshot: NinebotVehicleSnapshot
    var weather: RideWeatherSnapshot
    var size: CGSize
    var phase: TimeInterval
    var startPulse: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fireworkProgress: Double = 0
    @State private var hasSeenBattery = false

    private var battery: Int? { snapshot.state.battery }

    var body: some View {
        let currentPulse = reduceMotion ? 0.9 : 0.76 + 0.24 * (0.5 + 0.5 * sin(phase * 3.4))

        return ZStack(alignment: .topLeading) {
            VehicleSceneBackdrop(size: size, phase: phase, style: .charging, weather: weather)

            VehicleSceneHeader(
                title: snapshot.state.isFullyCharged ? "充电完成" : "正在充电",
                subtitle: snapshot.state.isFullyCharged ? "电池已达到安全上限" : "能量正在稳定注入",
                tint: Color.teslaGreen
            )
            .padding(.leading, 20)
            .padding(.top, 18)

            ChargingTelemetryHUD(state: snapshot.state)
                .frame(width: min(size.width * 0.40, 168), alignment: .leading)
                .padding(.leading, 18)
                .padding(.top, 76)

            Ellipse()
                .fill(Color.black.opacity(0.42))
                .frame(width: size.width * 0.54, height: size.height * 0.07)
                .blur(radius: 8)
                .offset(x: size.width * 0.24, y: size.height * 0.82)

            VehicleImage(
                urlString: snapshot.vehicle.imageURLString,
                sn: snapshot.vehicle.sn,
                size: min(size.width * 0.60, 250),
                showsBackground: false
            )
            .shadow(color: .black.opacity(0.44), radius: 14, x: 0, y: 9)
            .position(x: size.width * 0.52, y: size.height * 0.67)

            VehicleChargingCable(size: size, phase: phase)
                .opacity(currentPulse)

            ChargingStartWave(size: size, progress: startPulse)
            ChargingBatteryFireworks(size: size, progress: fireworkProgress)

            VehicleChargePillar(pulse: currentPulse)
                .frame(width: size.width * 0.15, height: size.height * 0.48)
                .position(x: size.width * 0.84, y: size.height * 0.45)

            ChargingSteps(active: snapshot.state.isFullyCharged ? 4 : 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            hasSeenBattery = battery != nil
        }
        .onChange(of: battery) { oldValue, newValue in
            guard hasSeenBattery, let oldValue, let newValue, newValue > oldValue else {
                hasSeenBattery = true
                return
            }
            triggerBatteryFireworks()
        }
    }

    private func triggerBatteryFireworks() {
        fireworkProgress = 0.01
        withAnimation(.easeOut(duration: 0.85)) {
            fireworkProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 950_000_000)
            fireworkProgress = 0
        }
    }
}

private struct ChargingTelemetryHUD: View {
    var state: NinebotVehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: state.batteryFraction)
                        .stroke(Color.teslaGreen, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.teslaGreen)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 0) {
                    Text("当前电量")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                    Text(state.batteryText)
                        .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }

            Rectangle()
                .fill(Color.teslaGreen.opacity(0.8))
                .frame(width: 48, height: 2)

            HStack(spacing: 15) {
                ChargingTelemetryValue(title: "预计充满", value: state.estimatedFullChargeClockText, icon: "clock")
                ChargingTelemetryValue(title: "充电功率", value: state.chargingPowerText, icon: "waveform.path.ecg")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前电量 \(state.batteryText)，预计 \(state.estimatedFullChargeClockText) 充满，充电功率 \(state.chargingPowerText)")
    }
}

private struct ChargingTelemetryValue: View {
    var title: String
    var value: String
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.63))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
    }
}

private struct ChargingStartWave: View {
    var size: CGSize
    var progress: Double

    var body: some View {
        let origin = CGPoint(x: size.width * 0.58, y: size.height * 0.67)
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let delay = Double(index) * 0.12
                let local = min(max((progress - delay) / (1 - delay), 0), 1)
                Circle()
                    .stroke(Color.teslaGreen.opacity((1 - local) * 0.75), lineWidth: 1.5)
                    .frame(width: 30 + CGFloat(local) * 130, height: 30 + CGFloat(local) * 130)
                    .position(origin)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChargingBatteryFireworks: View {
    var size: CGSize
    var progress: Double

    var body: some View {
        let origin = CGPoint(x: size.width * 0.53, y: size.height * 0.58)
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                let angle = Double(index) * (.pi * 2 / 12)
                let delay = Double(index % 3) * 0.06
                let local = min(max((progress - delay) / (1 - delay), 0), 1)
                Circle()
                    .fill(index.isMultiple(of: 2) ? Color.white : Color.teslaGreen)
                    .frame(width: index.isMultiple(of: 3) ? 4 : 3, height: index.isMultiple(of: 3) ? 4 : 3)
                    .shadow(color: Color.teslaGreen, radius: 5)
                    .scaleEffect(0.7 + local * 0.8)
                    .position(
                        x: origin.x + cos(angle) * (16 + 54 * local),
                        y: origin.y + sin(angle) * (16 + 54 * local)
                    )
                    .opacity((1 - local) * 0.95)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChargingGarageBackdrop: View {
    var isDay: Bool
    var size: CGSize

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isDay
                    ? [Color(red: 0.10, green: 0.18, blue: 0.24), Color(red: 0.04, green: 0.09, blue: 0.13)]
                    : [Color(red: 0.015, green: 0.025, blue: 0.08), Color(red: 0.02, green: 0.08, blue: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.teslaGreen.opacity(isDay ? 0.18 : 0.24), .clear],
                center: .init(x: 0.58, y: 0.52),
                startRadius: 4,
                endRadius: size.width * 0.7
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.cyan.opacity(isDay ? 0.22 : 0.30))
                        .frame(width: size.width * 0.42)
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                }
                .frame(height: size.height * 0.60)
                Spacer()
            }

            ChargingFloorGrid(size: size)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.cyan.opacity(0.65))
                    .frame(height: 1)
                    .shadow(color: .cyan, radius: 8)
                Spacer()
            }
            .padding(.top, size.height * 0.12)

            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.black.opacity(0.56)], startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct ChargingFloorGrid: View {
    var size: CGSize

    var body: some View {
        Path { path in
            let horizonY = size.height * 0.56
            let bottomY = size.height * 0.98
            let vanishingX = size.width * 0.56

            for index in 0..<7 {
                let progress = CGFloat(index) / 6
                let y = horizonY + pow(progress, 1.65) * (bottomY - horizonY)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            for index in 0..<9 {
                let x = CGFloat(index) / 8 * size.width
                path.move(to: CGPoint(x: vanishingX, y: horizonY))
                path.addLine(to: CGPoint(x: x, y: bottomY))
            }
        }
        .stroke(Color.cyan.opacity(0.13), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct VehicleChargePillar: View {
    var pulse: Double

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.teslaGreen.opacity(0.16))
                .frame(width: 70, height: 160)
                .blur(radius: 18)

            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color.black.opacity(0.94), Color(red: 0.08, green: 0.14, blue: 0.17)], startPoint: .top, endPoint: .bottom))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.cyan.opacity(0.42), lineWidth: 1)
                        }

                    VStack(spacing: 6) {
                        Text("DC / 01")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                        Circle()
                            .fill(Color.teslaGreen.opacity(pulse))
                            .frame(width: 9, height: 9)
                            .shadow(color: Color.teslaGreen, radius: 9)
                        Capsule()
                            .fill(Color.teslaGreen.opacity(pulse))
                            .frame(width: 4, height: 22)
                            .shadow(color: Color.teslaGreen, radius: 8)
                    }
                }
                .frame(height: 64)

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color.black.opacity(0.94), Color.black.opacity(0.56)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.teslaGreen.opacity(pulse))
                            .frame(width: 3, height: 28)
                            .padding(.leading, 6)
                    }
                    .overlay(alignment: .trailing) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.teslaGreen.opacity(pulse))
                            .padding(.trailing, 9)
                    }
                    .frame(height: 72)

                Capsule()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 42, height: 5)
            }
        }
        .shadow(color: .black.opacity(0.36), radius: 13, x: -4, y: 8)
        .accessibilityHidden(true)
    }
}

private struct VehicleChargingCable: View {
    var size: CGSize
    var phase: TimeInterval

    var body: some View {
        let chargerPort = CGPoint(x: size.width * 0.83, y: size.height * 0.34)
        let batteryPort = CGPoint(x: size.width * 0.58, y: size.height * 0.67)
        let control1 = CGPoint(x: size.width * 0.73, y: size.height * 0.80)
        let control2 = CGPoint(x: size.width * 0.64, y: size.height * 0.51)

        return ZStack {
            chargingCablePath(chargerPort: chargerPort, batteryPort: batteryPort, control1: control1, control2: control2)
                .stroke(.black.opacity(0.78), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            chargingCablePath(chargerPort: chargerPort, batteryPort: batteryPort, control1: control1, control2: control2)
                .stroke(Color.teslaGreen.opacity(0.86), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 10], dashPhase: phase * -30))
                .shadow(color: Color.teslaGreen.opacity(0.9), radius: 6)

            ForEach(0..<6, id: \.self) { index in
                let progress = (phase * 0.42 + Double(index) * 0.16).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: index.isMultiple(of: 2) ? 4 : 3, height: index.isMultiple(of: 2) ? 4 : 3)
                    .shadow(color: Color.teslaGreen, radius: 7)
                    .position(chargingCubicPoint(from: chargerPort, to: batteryPort, control1: control1, control2: control2, progress: progress))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func chargingCablePath(chargerPort: CGPoint, batteryPort: CGPoint, control1: CGPoint, control2: CGPoint) -> Path {
        Path { path in
            path.move(to: chargerPort)
            path.addCurve(to: batteryPort, control1: control1, control2: control2)
        }
    }
}

private func chargingCubicPoint(from start: CGPoint, to end: CGPoint, control1: CGPoint, control2: CGPoint, progress: Double) -> CGPoint {
    let t = min(max(progress, 0), 1)
    let inverse = 1 - t
    let x = inverse * inverse * inverse * start.x
        + 3 * inverse * inverse * t * control1.x
        + 3 * inverse * t * t * control2.x
        + t * t * t * end.x
    let y = inverse * inverse * inverse * start.y
        + 3 * inverse * inverse * t * control1.y
        + 3 * inverse * t * t * control2.y
        + t * t * t * end.y
    return CGPoint(x: x, y: y)
}

private struct ChargingSteps: View {
    var active: Int

    private let steps = [
        ("powerplug.fill", "连接电源"),
        ("bolt.fill", "开始充电"),
        ("battery.75percent", "充电中"),
        ("checkmark", "充电完成")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, stepValue in
                step(icon: stepValue.0, title: stepValue.1, index: index + 1)
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index + 1 < active ? Color.teslaGreen.opacity(0.9) : .white.opacity(0.22))
                        .frame(width: 24, height: 1)
                        .padding(.horizontal, 3)
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("充电流程，已完成第 \(active) 步")
    }

    private func step(icon: String, title: String, index: Int) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(index <= active ? Color.teslaGreen.opacity(0.18) : .white.opacity(0.08))
                    .frame(width: 29, height: 29)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(index <= active ? Color.teslaGreen : .white.opacity(0.42))
            }
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(index <= active ? Color.teslaGreen : .white.opacity(0.46))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TeslaHeroMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BatteryProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.teslaControlBackground)

                Capsule()
                    .fill(Color.teslaGreen)
                    .frame(width: max(proxy.size.width * value, 8))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("电量进度 \(Int(value * 100))%")
    }
}

private struct StatusChip: View {
    var title: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.teslaCardBackground)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
    }
}

private struct ControlMetricPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleLocationRideSummaryPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var resolvedAddress: String?
    var isLoading: Bool
    var onOpenTrips: () -> Void
    var onRingBell: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VehicleLocationSummaryCard(
                snapshot: snapshot,
                resolvedAddress: resolvedAddress,
                isLoading: isLoading,
                onRingBell: onRingBell
            )
            .frame(maxWidth: .infinity)

            Button(action: onOpenTrips) {
                VehicleRideSummaryGroupCard(snapshot: snapshot)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 198)
    }
}

private struct VehicleLocationSummaryCard: View {
    var snapshot: NinebotVehicleSnapshot
    var resolvedAddress: String?
    var isLoading: Bool
    var onRingBell: () -> Void

    var body: some View {
        if let coordinate = vehicleCoordinate(snapshot.state) {
            NavigationLink {
                NinebotVehicleMapView(
                    snapshot: snapshot,
                    address: normalizedLocationText,
                    coordinate: coordinate,
                    isLoading: isLoading,
                    onRingBell: onRingBell
                )
            } label: {
                content(coordinate: coordinate)
            }
            .buttonStyle(.plain)
        } else {
            content(coordinate: nil)
        }
    }

    private func content(coordinate: CLLocationCoordinate2D?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("车辆位置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("更新自\(formatTime(snapshot.state.updatedAt))")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ZStack(alignment: .bottomLeading) {
                if let coordinate {
                    VehicleLocationPreviewMap(coordinate: coordinate)
                } else {
                    ZStack {
                        Color.teslaControlBackground
                        Image(systemName: "map")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.teslaSecondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(locationTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.top, 28)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(
                        colors: [
                            Color.teslaCardBackground.opacity(0.98),
                            Color.teslaCardBackground.opacity(0.82),
                            Color.teslaCardBackground.opacity(0)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 18,
                style: .continuous
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var normalizedLocationText: String? {
        guard let value = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var locationTitle: String {
        if let normalizedLocationText {
            return normalizedLocationText
        }
        if let description = snapshot.state.locationDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        if let coordinate = vehicleCoordinate(snapshot.state) {
            return coordinateText(coordinate.latitude, coordinate.longitude)
        }
        return "暂无车辆位置"
    }
}

private struct VehicleLocationPreviewMap: View {
    var coordinate: CLLocationCoordinate2D
    @State private var cameraPosition: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        _cameraPosition = State(initialValue: .region(Self.region(for: coordinate)))
    }

    var body: some View {
        Map(position: $cameraPosition) {
            Marker("车辆", systemImage: "scooter", coordinate: coordinate)
                .tint(Color.teslaGreen)
        }
        .allowsHitTesting(false)
    }

    private static func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0048, longitudeDelta: 0.0048)
        )
    }
}

private struct VehicleRideSummaryGroupCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("行程", systemImage: "road.lanes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 8) {
                VehicleRideSummaryTile(
                    title: "最近骑行",
                    value: formatDistanceNumber(snapshot.state.lastMileage),
                    unit: "km",
                    systemImage: "arrow.left.arrow.right",
                    isPrimary: true
                )

                VehicleRideSummaryTile(
                    title: "总行程",
                    value: formatDistanceNumber(snapshot.state.totalMileage),
                    unit: "km",
                    systemImage: "calendar",
                    isPrimary: false
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleRideSummaryTile: View {
    var title: String
    var value: String
    var unit: String
    var systemImage: String
    var isPrimary: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: isPrimary ? 30 : 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.52)
                Text(unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isPrimary ? Color.teslaGreen.opacity(0.10) : Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleRideMetricCard: View {
    var title: String
    var value: String
    var unit: String
    var systemImage: String
    var isProminent: Bool

    var body: some View {
        Group {
            if isProminent {
                prominentContent
            } else {
                compactContent
            }
        }
        .padding(14)
        .frame(height: isProminent ? 110 : 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.02), radius: 10, x: 0, y: 4)
    }

    private var prominentContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
            }
        }
    }

    private var compactContent: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text(unit)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
        }
    }
}

private struct VehicleRangeEstimatePanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("预估可行驶")
                        .font(.headline)
                    Text(snapshot.state.localEstimateBasisText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(snapshot.state.localEstimatedMileageText)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            RangeEstimateBar(batteryFraction: snapshot.state.batteryFraction)

            HStack(spacing: 10) {
                BasicInfoTile(title: "本地模型", value: snapshot.state.localEstimatedMileageText, systemImage: "function")
                BasicInfoTile(title: "行程最高速度", value: snapshot.state.maximumSpeedText, systemImage: "speedometer")
                BasicInfoTile(title: "接口续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.02), radius: 10, x: 0, y: 4)
    }
}

private struct RangeEstimateBar: View {
    var batteryFraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.teslaControlBackground)

                Capsule()
                    .fill(Color.teslaGreen.opacity(0.9))
                    .frame(width: max(proxy.size.width * batteryFraction, 8))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("剩余电量 \(Int(batteryFraction * 100))%")
    }
}

private struct VehicleHealthPanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        let warnings = snapshot.state.warningTexts
        let health = snapshot.state.health

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(healthColor(health.level).opacity(0.14))
                    Image(systemName: snapshot.state.isCharging == true ? "bolt.fill" : "battery.100")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(snapshot.state.isCharging == true ? Color.teslaGreen : batteryTextColor(snapshot.state))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text("电池")
                        .font(.headline)
                    Text(snapshot.state.isCharging == true ? snapshot.state.chargeSummaryText : "查看电压、温度和充电信息")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(snapshot.state.batteryText)
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(batteryTextColor(snapshot.state))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                .frame(alignment: .center)
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleUsagePanel: View {
    var snapshot: NinebotVehicleSnapshot
    var showsDisclosure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("用车统计")
                        .font(.headline)
                    Text("完整行程和能耗进详情查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showsDisclosure {
                    HStack(spacing: 4) {
                        Text("行程")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "本月日均", value: snapshot.state.dailyAverageMileageText, systemImage: "calendar")
                BasicInfoTile(title: "最近骑行", value: snapshot.state.lastRideSummaryText, systemImage: "clock.arrow.circlepath")
                BasicInfoTile(title: "行程最高速度", value: snapshot.state.maximumSpeedText, systemImage: "speedometer")
                BasicInfoTile(title: "本月能耗", value: snapshot.state.monthEnergyPerKmText, systemImage: "bolt.horizontal.fill")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripHeroPanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("行程概要")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(snapshot.vehicle.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(snapshot.state.rangeEstimateAccuracyText)
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaGreen)
                    Text("预估准确率")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(snapshot.state.localEstimatedMileageText)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("预计可行驶")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "今日里程", value: snapshot.state.todayMileageText, systemImage: "sun.max.fill")
                BasicInfoTile(title: "最高速度", value: snapshot.state.maximumSpeedText, systemImage: "speedometer")
                BasicInfoTile(title: "有效样本", value: "\(snapshot.state.observedRangeSampleCount) 次", systemImage: "scope")
                BasicInfoTile(title: "本月日均", value: snapshot.state.dailyAverageMileageText, systemImage: "calendar")
            }

            Label(snapshot.state.rangeEstimateAccuracyDetailText, systemImage: "target")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendEntryCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teslaGreen.opacity(0.14))
                Image(systemName: "chart.xyaxis.line")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("查看趋势")
                    .font(.headline)
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("里程、用电、速度和续航估算表现")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(snapshot.state.monthMileageText)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendView: View {
    var snapshot: NinebotVehicleSnapshot
    var recordedRides: [NinebotRecordedRide]

    private var analysis: TripTrendAnalysis {
        TripTrendAnalysis(snapshot: snapshot, recordedRides: recordedRides)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TripTrendHeroCard(snapshot: snapshot, analysis: analysis)
                TripTrendRangeModelCard(snapshot: snapshot)
                TripTrendDailyCard(records: analysis.dailyRecords)
                TripTrendRideCard(analysis: analysis)
                TripTrendInsightCard(analysis: analysis)

                if !recordedRides.isEmpty {
                    TripTrendRecordedCard(records: recordedRides)
                }
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("趋势分析")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TripTrendRangeModelCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地续航模型")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(snapshot.state.rangeModelInsightText)
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer(minLength: 8)

                Text(snapshot.state.localEstimatedMileageText)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "准确率", value: snapshot.state.rangeEstimateAccuracyText, systemImage: "target")
                BasicInfoTile(title: "有效样本", value: "\(snapshot.state.observedRangeSampleCount) 次", systemImage: "scope")
                BasicInfoTile(title: "近期效率", value: snapshot.state.rangePerBatteryPercentText, systemImage: "gauge.with.dots.needle.33percent")
                BasicInfoTile(title: "接口续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendHeroCard: View {
    var snapshot: NinebotVehicleSnapshot
    var analysis: TripTrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.vehicle.name)
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                    Text("趋势分析")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(snapshot.state.rangeEstimateAccuracyText)
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaGreen)
                    Text("预估准确率")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatDistance(analysis.monthMileage))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("当月行程")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            HStack(spacing: 10) {
                TrendHeroMetric(title: "骑行次数", value: "\(analysis.rideCount)", suffix: "次", systemImage: "list.number")
                TrendHeroMetric(title: "活跃天数", value: "\(analysis.activeDayCount)", suffix: "天", systemImage: "calendar")
                TrendHeroMetric(title: "单公里耗电", value: analysis.energyPerKmShortText, suffix: "Wh/km", systemImage: "bolt.horizontal.fill")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TrendHeroMetric: View {
    var title: String
    var value: String
    var suffix: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(suffix)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TripTrendDailyCard: View {
    var records: [NinebotDailyMileageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每日里程趋势")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(records.isEmpty ? "等待接口返回本月 detail" : "最近 \(visibleRecords.count) 天")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text(formatDistance(records.map(\.mileage).max()))
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            if records.isEmpty {
                EmptyTrendState(text: "暂无每日里程趋势")
            } else {
                TrendBarChart(values: visibleRecords.map { record in
                    TrendBarValue(
                        id: record.id,
                        label: "\(record.day)",
                        value: record.mileage,
                        tint: Color.teslaGreen
                    )
                })
                .frame(height: 176)

                HStack(spacing: 10) {
                    ControlMetricPill(title: "日均", value: formatDistance(averageMileage), systemImage: "chart.bar.xaxis")
                    ControlMetricPill(title: "最高", value: formatDistance(peakMileage), systemImage: "arrow.up.right")
                    ControlMetricPill(title: "活跃", value: "\(records.count) 天", systemImage: "calendar")
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private var visibleRecords: [NinebotDailyMileageRecord] {
        Array(records.suffix(14))
    }

    private var averageMileage: Double? {
        guard !records.isEmpty else { return nil }
        return records.reduce(0) { $0 + $1.mileage } / Double(records.count)
    }

    private var peakMileage: Double? {
        records.map(\.mileage).max()
    }
}

private struct TripTrendRideCard: View {
    var analysis: TripTrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近骑行表现")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(analysis.recentRides.isEmpty ? "等待行程列表" : "最近 \(analysis.recentRides.count) 次")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text(formatSpeed(analysis.maximumSpeed))
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            if analysis.recentRides.isEmpty {
                EmptyTrendState(text: "暂无最近骑行数据")
            } else {
                TripRecentRideBars(records: analysis.recentRides)
                    .frame(height: 168)

                HStack(spacing: 10) {
                    ControlMetricPill(title: "最高速度", value: formatSpeed(analysis.maximumSpeed), systemImage: "speedometer")
                    ControlMetricPill(title: "平均用电", value: formatPercent(analysis.averageUsedElectricity), systemImage: "powerplug.fill")
                    ControlMetricPill(title: "最高里程", value: formatDistance(analysis.peakRideMileage), systemImage: "arrow.up.right")
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendInsightCard: View {
    var analysis: TripTrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地模型提示")
                .font(.headline)
                .foregroundStyle(Color.teslaPrimaryText)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(analysis.insights, id: \.self) { insight in
                    Label(insight, systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendRecordedCard: View {
    var records: [NinebotRecordedRide]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地记录")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("记录页生成的轨迹统计")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text("\(records.count) 次")
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "本地总里程", value: formatDistance(records.reduce(0) { $0 + $1.distanceKilometers }), systemImage: "point.3.connected.trianglepath.dotted")
                BasicInfoTile(title: "本地极速", value: formatSpeed(records.map(\.maxSpeedKmh).max()), systemImage: "gauge.with.dots.needle.67percent")
                BasicInfoTile(title: "最大 G", value: formatAccelerationG(records.map(\.maxAccelerationG).max()), systemImage: "bolt.circle.fill")
                BasicInfoTile(title: "已关联", value: "\(records.filter { $0.associatedRideID != nil }.count) 次", systemImage: "link")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TrendBarValue: Identifiable {
    var id: String
    var label: String
    var value: Double
    var tint: Color
}

private struct TrendBarChart: View {
    var values: [TrendBarValue]

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(values.map(\.value).max() ?? 0, 1)
            let chartHeight = max(proxy.size.height - 42, 1)
            let barWidth = min(max(proxy.size.width / CGFloat(max(values.count, 1)) * 0.24, 4), 11)

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Divider()
                            .opacity(0.55)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 20)

                HStack(alignment: .bottom, spacing: values.count > 10 ? 7 : 10) {
                    ForEach(values) { item in
                        VStack(spacing: 6) {
                            Text(shortTrendValue(item.value))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            ZStack(alignment: .bottom) {
                                Capsule()
                                    .fill(Color.teslaSecondaryText.opacity(0.10))
                                    .frame(width: barWidth, height: chartHeight)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [item.tint.opacity(0.72), item.tint],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: barWidth, height: max(6, chartHeight * CGFloat(item.value / maxValue)))
                            }

                            Text(item.label)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TripRecentRideBars: View {
    var records: [NinebotRideRecord]

    var body: some View {
        TrendBarChart(values: Array(records.enumerated()).map { index, ride in
            TrendBarValue(
                id: ride.id,
                label: "\(index + 1)",
                value: ride.mileage ?? 0,
                tint: ride.usedElectricity.map { $0 > 15 ? Color.orange : Color.teslaGreen } ?? Color.teslaGreen
            )
        })
    }
}

private struct EmptyTrendState: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.teslaSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.teslaControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TripTrendAnalysis {
    var snapshot: NinebotVehicleSnapshot
    var recordedRides: [NinebotRecordedRide]

    var dailyRecords: [NinebotDailyMileageRecord] {
        snapshot.state.dailyMileages.sorted {
            if let left = $0.date, let right = $1.date {
                return left < right
            }
            return $0.day < $1.day
        }
    }

    var rides: [NinebotRideRecord] {
        snapshot.state.rides
    }

    var recentRides: [NinebotRideRecord] {
        Array(rides.prefix(8))
    }

    var rideCount: Int {
        rides.count
    }

    var activeDayCount: Int {
        dailyRecords.count
    }

    var monthMileage: Double? {
        if let monthMileage = snapshot.state.monthMileage {
            return monthMileage
        }
        guard !dailyRecords.isEmpty else { return nil }
        return dailyRecords.reduce(0) { $0 + $1.mileage }
    }

    var averageDailyMileage: Double? {
        guard let monthMileage, !dailyRecords.isEmpty else { return nil }
        return monthMileage / Double(dailyRecords.count)
    }

    var averageSpeed: Double? {
        let samples = rides.compactMap(\.speed).filter { $0 > 0 }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var maximumSpeed: Double? {
        snapshot.state.maximumSpeed
    }

    var averageUsedElectricity: Double? {
        let samples = rides.compactMap(\.usedElectricity).filter { $0 > 0 }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var peakRideMileage: Double? {
        rides.compactMap(\.mileage).max()
    }

    var energyPerKm: Double? {
        if let monthMileage, monthMileage > 0,
           let energy = snapshot.state.monthUsedElectricity ?? snapshot.state.monthEnergy {
            return energy / monthMileage
        }

        let samples = rides.compactMap { ride -> Double? in
            guard let mileage = ride.mileage, mileage > 0,
                  let energy = ride.energy, energy > 0 else { return nil }
            return energy / mileage
        }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var energyPerKmText: String {
        guard let energyPerKm else { return "-- Wh/km" }
        return "\(formatNumber(energyPerKm, unit: " Wh/km", maximumFractionDigits: 1))"
    }

    var energyPerKmShortText: String {
        guard let energyPerKm else { return "--" }
        return formatNumber(energyPerKm, unit: "", maximumFractionDigits: 1)
    }

    var insights: [String] {
        var result: [String] = []

        if let peak = peakRideMileage, let averageDailyMileage, peak > averageDailyMileage * 1.8 {
            result.append("有长距离单次骑行，续航预估会更依赖最近行程样本。")
        }

        if let averageUsedElectricity, averageUsedElectricity > 12 {
            result.append("最近单次平均用电偏高，可以关注胎压、载重和急加速。")
        }

        if let energyPerKm, energyPerKm > 35 {
            result.append("单公里耗电偏高，后续可以结合温度和速度继续校准。")
        }

        if snapshot.state.observedRangeSampleCount < 5 {
            result.append("有效续航样本还不多，多记录几次后准确率会更稳定。")
        }

        if recordedRides.contains(where: { $0.associatedRideID == nil }) {
            result.append("有本地记录尚未关联接口行程，关联后趋势会更完整。")
        }

        if result.isEmpty {
            result.append("当前趋势正常，继续积累行程后可以看到更稳定的变化。")
        }

        return result
    }
}

private struct DailyMileagePanel: View {
    var records: [NinebotDailyMileageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每日里程")
                        .font(.headline)
                    Text(records.isEmpty ? "等待行程接口返回 detail" : "按每日总里程生成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formatDistance(totalMileage))
                    .font(.headline.monospacedDigit().weight(.semibold))
            }

            if records.isEmpty {
                Text("暂无每日里程数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                DailyMileageLineChart(records: records)
                    .frame(height: 128)

                HStack(spacing: 10) {
                    ControlMetricPill(title: "最高", value: formatDistance(peakMileage), systemImage: "arrow.up.right")
                    ControlMetricPill(title: "平均", value: formatDistance(averageMileage), systemImage: "chart.bar.xaxis")
                    ControlMetricPill(title: "天数", value: "\(records.count) 天", systemImage: "calendar")
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }

    private var totalMileage: Double? {
        guard !records.isEmpty else { return nil }
        return records.reduce(0) { $0 + $1.mileage }
    }

    private var averageMileage: Double? {
        guard let totalMileage, !records.isEmpty else { return nil }
        return totalMileage / Double(records.count)
    }

    private var peakMileage: Double? {
        records.map(\.mileage).max()
    }
}

private struct DailyMileageLineChart: View {
    var records: [NinebotDailyMileageRecord]

    var body: some View {
        GeometryReader { proxy in
            let points = chartPoints(in: proxy.size)

            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Divider()
                        Spacer(minLength: 0)
                    }
                    Divider()
                }
                .opacity(0.45)

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: [Color.teslaGreen.opacity(0.65), Color.teslaGreen],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(Color(.systemBackground))
                        .overlay {
                            Circle()
                                .stroke(Color.teslaGreen, lineWidth: 2)
                        }
                        .frame(width: index == points.count - 1 ? 8 : 6, height: index == points.count - 1 ? 8 : 6)
                        .position(point)
                }
            }
        }
        .padding(12)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("每日里程折线图")
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        guard !records.isEmpty else { return [] }
        let maxMileage = max(records.map(\.mileage).max() ?? 0, 1)
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let count = records.count

        return records.enumerated().map { index, record in
            let x = count == 1 ? width / 2 : width * CGFloat(index) / CGFloat(count - 1)
            let y = height - height * CGFloat(record.mileage / maxMileage)
            return CGPoint(x: x, y: min(max(y, 0), height))
        }
    }
}

private struct VehicleHistoryPanel: View {
    var points: [NinebotVehicleHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("历史记录")
                        .font(.headline)
                    Text("每次刷新后自动记录本地快照")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let summary = NinebotVehicleHistorySummary(points: points) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    BasicInfoTile(title: "记录周期", value: summary.periodText, systemImage: "clock")
                    BasicInfoTile(title: "样本数", value: "\(summary.sampleCount)", systemImage: "list.bullet.rectangle")
                    BasicInfoTile(title: "电量变化", value: summary.batteryDeltaText, systemImage: "battery.100")
                    BasicInfoTile(title: "里程变化", value: summary.mileageDeltaText, systemImage: "road.lanes")
                }
            } else {
                Text("刷新一次车况后开始记录趋势")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleHeroCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 78)

                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.vehicle.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(snapshot.vehicle.model)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(snapshot.vehicle.sn)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                BatteryGauge(value: snapshot.state.battery)
                    .frame(width: 62, height: 62)
            }

            HStack(spacing: 22) {
                MetricView(title: "续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
                MetricView(title: "锁车", value: snapshot.state.lockText, systemImage: snapshot.state.isLocked == true ? "lock.fill" : "lock.open.fill")
                MetricView(title: "电源", value: snapshot.state.powerText, systemImage: "power")
            }

            Divider()

            Label("更新 \(formatDate(snapshot.state.updatedAt))", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleActionPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var isLoading: Bool
    var activeAction: NinebotVehicleAction?
    var onAction: (NinebotVehicleAction) -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let activeAction {
                VehicleControlLoadingStrip(action: activeAction)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(alignment: .center, spacing: 12) {
                CommandPadButton(
                    title: "寻车",
                    systemImage: "bell.fill",
                    tint: Color.teslaPrimaryText,
                    isLoading: activeAction == .bell,
                    isDisabled: isLoading
                ) {
                    onAction(.bell)
                }

                SlideActionControl(
                    title: isLocked ? "滑动开锁" : "滑动关锁",
                    completedTitle: isLocked ? "正在开锁" : "正在关锁",
                    systemImage: isLocked ? "lock.fill" : "lock.open.fill",
                    color: Color.teslaGreen,
                    isLoading: activeAction == slideAction,
                    isDisabled: isLoading
                ) {
                    onAction(slideAction)
                }
                .id(isLocked ? "unlock" : "lock")

                CommandPadButton(
                    title: "座桶",
                    systemImage: "shippingbox.fill",
                    tint: Color.teslaPrimaryText,
                    isLoading: activeAction == .openBucket,
                    isDisabled: isLoading
                ) {
                    onAction(.openBucket)
                }
            }
        }
        .padding(12)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
        .padding(.horizontal, 16)
    }

    private var isLocked: Bool {
        snapshot.state.isLocked != false
    }

    private var slideAction: NinebotVehicleAction {
        isLocked ? .engineStart : .engineStop
    }
}

private struct VehicleControlLoadingStrip: View {
    var action: NinebotVehicleAction

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.teslaGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.loadingTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("发送完成后自动刷新车况")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.teslaGreen.opacity(0.24), lineWidth: 1)
        }
    }
}

private struct CommandPadButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var isLoading: Bool
    var isDisabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.teslaControlBackground)
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.05), lineWidth: 1)
                        }
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.teslaGreen)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 44, height: 44)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: 70, height: 64)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isLoading ? 0.45 : 1)
    }
}

private struct SlideActionControl: View {
    var title: String
    var completedTitle: String
    var systemImage: String
    var color: Color
    var isLoading: Bool
    var isDisabled: Bool
    var onCommit: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isCommitted = false
    @State private var isDragging = false

    private let height: CGFloat = 64
    private let thumbSize: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            let maxOffset = max(proxy.size.width - thumbSize - 10, 0)
            let isBusy = isLoading || isCommitted

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.teslaControlBackground)
                    .overlay {
                        Capsule()
                            .stroke(Color.teslaHairline, lineWidth: 1)
                    }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.42), color.opacity(0.16)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbSize + dragOffset, thumbSize))
                    .opacity(isDragging || isCommitted ? 1 : 0)

                HStack(spacing: 8) {
                    Spacer(minLength: thumbSize + 8)

                    HStack(spacing: 8) {
                        Text(isBusy ? completedTitle : title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(color)
                        } else if !isCommitted {
                            HStack(spacing: -2) {
                                Image(systemName: "chevron.right")
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(color)
                        }
                    }
                    .offset(x: 10)

                    Spacer(minLength: 12)
                }
                .foregroundStyle(isDisabled && !isLoading ? Color.teslaSecondaryText : Color.teslaPrimaryText)
                .padding(.horizontal, 12)

                ZStack {
                    Circle()
                        .fill(Color.teslaActionThumb)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 4)
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: thumbSize, height: thumbSize)
                .padding(5)
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard !isDisabled, !isCommitted else { return }
                            isDragging = true
                            dragOffset = min(max(value.translation.width, 0), maxOffset)
                        }
                        .onEnded { _ in
                            guard !isDisabled, !isCommitted else { return }
                            if dragOffset >= maxOffset * 0.72 {
                                isCommitted = true
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    dragOffset = maxOffset
                                }
                                onCommit()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        dragOffset = 0
                                        isCommitted = false
                                        isDragging = false
                                    }
                                }
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    dragOffset = 0
                                    isDragging = false
                                }
                            }
                        }
                )
            }
        }
        .frame(height: height)
        .opacity(isDisabled && !isLoading ? 0.55 : 1)
        .accessibilityLabel(title)
    }
}

private struct VehicleBasicsPanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teslaControlBackground)
                Image(systemName: "info.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("查看信息")
                    .font(.headline)
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("\(snapshot.vehicle.model) · 更新 \(formatTime(snapshot.state.updatedAt))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.teslaSecondaryText)
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct BasicInfoTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .frame(width: 22, height: 22, alignment: .leading)

            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleDetailPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var resolvedAddress: String?
    var isLoading: Bool
    var onRingBell: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("详细信息")
                .font(.headline)

            DetailSection(title: "车况") {
                DetailRow(title: "健康状态", value: snapshot.state.health.title, systemImage: snapshot.state.health.systemImage)
                DetailRow(title: "状态说明", value: snapshot.state.health.message, systemImage: "text.bubble.fill")
                DetailRow(title: "电量", value: snapshot.state.batteryText, systemImage: "battery.100")
                DetailRow(title: "电池电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                DetailRow(title: "电池温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
                DetailRow(title: "循环次数", value: snapshot.state.batteryCycleCountText, systemImage: "arrow.trianglehead.2.clockwise")
                DetailRow(title: "充电功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
                DetailRow(title: "预估续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
                DetailRow(title: "AI 预估", value: snapshot.state.aiEstimatedMileageText, systemImage: "sparkles")
                DetailRow(title: "本地预估", value: snapshot.state.localEstimatedMileageText, systemImage: "function")
                DetailRow(title: "本地模型", value: snapshot.state.rangeModelSummaryText, systemImage: "target")
                DetailRow(title: "续航可信", value: snapshot.state.rangePerBatteryPercentText, systemImage: "speedometer")
                DetailRow(title: "充电状态", value: snapshot.state.chargingStateText, systemImage: "bolt.fill")
                DetailRow(title: "充电速度", value: snapshot.state.estimatedChargingSpeedText, systemImage: "bolt.car.fill")
                DetailRow(title: "充至 80%", value: snapshot.state.estimatedChargeTo80TimeText, systemImage: "battery.75")
                DetailRow(title: "80% 时间", value: snapshot.state.estimatedChargeTo80ClockText, systemImage: "clock.badge.checkmark")
                DetailRow(title: "预计充满", value: snapshot.state.estimatedFullChargeTimeText, systemImage: "timer")
                DetailRow(title: "满电时间", value: snapshot.state.estimatedFullChargeClockText, systemImage: "clock.badge.checkmark.fill")
                DetailRow(title: "接口剩余", value: snapshot.state.remainingChargeTimeText, systemImage: "clock.badge.questionmark")
                DetailRow(title: "电源状态", value: snapshot.state.powerText, systemImage: "power")
                DetailRow(title: "锁车状态", value: snapshot.state.lockText, systemImage: snapshot.state.isLocked == true ? "lock.fill" : "lock.open.fill")
                DetailRow(title: "更新时间", value: formatDate(snapshot.state.updatedAt), systemImage: "clock")
            }

            DetailSection(title: "定位") {
                if let coordinate = vehicleCoordinate(snapshot.state) {
                    NavigationLink {
                        NinebotVehicleMapView(
                            snapshot: snapshot,
                            address: locationText,
                            coordinate: coordinate,
                            isLoading: isLoading,
                            onRingBell: onRingBell
                        )
                    } label: {
                        DetailRow(title: "位置", value: locationText, systemImage: "map")
                    }
                    .buttonStyle(.plain)
                } else {
                    DetailRow(title: "位置", value: locationText, systemImage: "map")
                }
                if hasResolvedAddress {
                    DetailRow(title: "地址来源", value: "Apple 地图解析", systemImage: "map.fill")
                }
                DetailRow(title: "纬度", value: formatCoordinate(snapshot.state.latitude), systemImage: "map")
                DetailRow(title: "经度", value: formatCoordinate(snapshot.state.longitude), systemImage: "map.fill")
                DetailRow(title: "坐标", value: coordinateText(snapshot.state.latitude, snapshot.state.longitude), systemImage: "location.fill")
            }

            DetailSection(title: "车辆资料") {
                DetailRow(title: "名称", value: snapshot.vehicle.name, systemImage: "tag.fill")
                DetailRow(title: "车型", value: snapshot.vehicle.model, systemImage: "bolt.car.fill")
                DetailRow(title: "SN", value: snapshot.vehicle.sn, systemImage: "number")
                DetailRow(title: "VIN", value: snapshot.vehicle.vin ?? "--", systemImage: "barcode.viewfinder")
                DetailRow(title: "图片", value: snapshot.vehicle.imageURLString ?? "--", systemImage: "photo")
            }

            RawFieldSection(title: "车辆原始字段", fields: snapshot.vehicle.raw)
            RawFieldSection(title: "状态原始字段", fields: snapshot.state.rawStatus)
            RawFieldSection(title: "电池原始字段", fields: snapshot.state.rawBattery)
            RawFieldSection(title: "行程原始字段", fields: snapshot.state.rawTravel)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var locationText: String {
        guard let resolvedAddress = normalizedResolvedAddress else {
            return snapshot.state.locationText
        }
        return resolvedAddress
    }

    private var hasResolvedAddress: Bool {
        normalizedResolvedAddress != nil
    }

    private var normalizedResolvedAddress: String? {
        guard let value = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct DetailSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content
            }
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct DetailRow: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(value.isEmpty ? "--" : value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct RideListSection: View {
    @ObservedObject var model: NinebotViewModel
    var records: [NinebotRideRecord]
    var recordedRides: [NinebotRecordedRide] = []
    var vehicleSN: String?
    var selectedMonth: String
    @State private var visibleLimit = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("行程列表")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("点击行程查看详情和本地轨迹")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text("\(records.count)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(tripMonthDisplayName(selectedMonth)) 暂无行程")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("可以切换已有月份，或继续向前获取服务器归档。")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.teslaCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.teslaHairline, lineWidth: 1)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(records.prefix(visibleLimit).enumerated()), id: \.element.id) { index, record in
                        NavigationLink {
                            NinebotRideDetailView(
                                model: model,
                                vehicleSN: vehicleSN,
                                record: record,
                                localRecord: associatedRecord(for: record)
                            )
                        } label: {
                            RideRecordRow(
                                record: record,
                                index: index
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if records.count > visibleLimit {
                        Button {
                            visibleLimit += 30
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.down.circle.fill")
                                Text("显示更多")
                                Text("\(records.count - visibleLimit)")
                                    .monospacedDigit()
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.teslaGreen)
                        .background(Color.teslaCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.teslaHairline, lineWidth: 1)
                        }
                    }
                }
            }
        }
        .onChange(of: selectedMonth) { _ in
            visibleLimit = 30
        }
    }

    private func associatedRecord(for record: NinebotRideRecord) -> NinebotRecordedRide? {
        recordedRides.first { ride in
            ride.associatedRideID == record.id && (vehicleSN == nil || ride.vehicleSN == nil || ride.vehicleSN == vehicleSN)
        }
    }
}

private struct RideRecordRow: View {
    var record: NinebotRideRecord
    var index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.teslaGreen.opacity(0.14))
                    Image(systemName: "road.lanes")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.startedAt.map(formatRideDate) ?? "行程 \(index + 1)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(record.endedAt.map { "结束 \($0.formatted(.dateTime.hour().minute()))" } ?? "结束时间未知")
                        Text("·")
                        Text(formatDuration(record.durationMinutes))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(formatDistance(record.mileage))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                }
            }

            if !metrics.isEmpty {
                HStack(spacing: 10) {
                    ForEach(metrics) { metric in
                        RideMetric(title: metric.title, value: metric.value, systemImage: metric.systemImage)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.teslaCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private var metrics: [RideDisplayMetric] {
        [
            record.energy.map { RideDisplayMetric(title: "能耗", value: formatEnergyWh($0), systemImage: "bolt.horizontal.fill") },
            record.usedElectricity.map { RideDisplayMetric(title: "用电", value: formatPercent($0), systemImage: "powerplug.fill") },
            record.speed.map { RideDisplayMetric(title: "最高速度", value: formatSpeed($0), systemImage: "speedometer") }
        ].compactMap { $0 }
    }
}

private struct RideDisplayMetric: Identifiable {
    var title: String
    var value: String
    var systemImage: String

    var id: String {
        "\(title)-\(value)-\(systemImage)"
    }
}

private struct NinebotRideDetailView: View {
    @ObservedObject var model: NinebotViewModel
    var vehicleSN: String?
    var record: NinebotRideRecord
    var localRecord: NinebotRecordedRide?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RideDetailHero(record: effectiveRecord, localRecord: localRecord)

                if let localRecord {
                    RideTrackExperiencePanel(
                        title: "本地轨迹",
                        sourceDescription: "本机定位记录 · \(formatDate(localRecord.startedAt)) - \(formatDate(localRecord.endedAt))",
                        points: localRecord.speedTrackPoints,
                        startedAt: localRecord.startedAt,
                        endedAt: localRecord.endedAt,
                        speedEstimationDurationSeconds: localRecord.durationSeconds,
                        distanceText: formatDistance(localRecord.distanceKilometers)
                    )
                } else if !interfaceTrackPoints.isEmpty {
                    RideTrackExperiencePanel(
                        title: "行程轨迹",
                        sourceDescription: "九号接口轨迹 · \(interfaceTrackPoints.count) 个定位点",
                        points: interfaceTrackSpeedPoints,
                        startedAt: effectiveRecord.startedAt,
                        endedAt: effectiveRecord.endedAt,
                        speedEstimationDurationSeconds: interfaceTrackDurationSeconds,
                        distanceText: formatDistance(effectiveRecord.mileage)
                    )
                }

                DetailSection(title: "接口行程") {
                    DetailRow(title: "开始时间", value: effectiveRecord.startedAt.map(formatDate) ?? "--", systemImage: "play.fill")
                    DetailRow(title: "结束时间", value: effectiveRecord.endedAt.map(formatDate) ?? "--", systemImage: "stop.fill")
                    DetailRow(title: "里程", value: formatDistance(effectiveRecord.mileage), systemImage: "road.lanes")
                    DetailRow(title: "时长", value: formatDuration(effectiveRecord.durationMinutes), systemImage: "timer")
                    DetailRow(title: "最高速度", value: formatSpeed(effectiveRecord.speed), systemImage: "speedometer")
                    DetailRow(title: "能耗", value: formatEnergyWh(effectiveRecord.energy), systemImage: "bolt.horizontal.fill")
                    DetailRow(title: "用电", value: formatPercent(effectiveRecord.usedElectricity), systemImage: "powerplug.fill")
                    DetailRow(title: "行程 ID", value: record.id, systemImage: "number")
                }

                RawJSONSection(title: "行程详情完整返回值", value: remoteDetail?.raw)
                RawFieldSection(title: "列表原始字段", fields: record.raw)
            }
            .padding(16)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("行程详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(vehicleSN ?? "")|\(record.id)") {
            await loadRemoteDetailIfNeeded()
        }
    }

    private var canLoadRemoteDetail: Bool {
        vehicleSN?.isEmpty == false && !record.id.isEmpty
    }

    private var remoteDetail: NinebotRideDetail? {
        guard let vehicleSN else { return nil }
        return model.rideDetail(vehicleSN: vehicleSN, rideID: record.id)
    }

    private var effectiveRecord: NinebotRideRecord {
        remoteDetail?.parsedRecord ?? record
    }

    private var interfaceTrackPoints: [NinebotInterfaceTrackPoint] {
        guard localRecord == nil else { return [] }
        return remoteDetail?.interfaceTrackPoints ?? []
    }

    private var interfaceTrackSpeedPoints: [TrackSpeedPoint] {
        interfaceTrackPoints.enumerated().map { index, point in
            TrackSpeedPoint(
                id: point.id.isEmpty ? "interface-\(index)" : point.id,
                coordinate: point.coordinate,
                speedKmh: point.speedKmh
            )
        }
    }

    private var interfaceTrackDurationSeconds: TimeInterval? {
        if let durationMinutes = effectiveRecord.durationMinutes, durationMinutes > 0 {
            return durationMinutes * 60
        }
        guard let startedAt = effectiveRecord.startedAt, let endedAt = effectiveRecord.endedAt else { return nil }
        let duration = endedAt.timeIntervalSince(startedAt)
        return duration > 0 ? duration : nil
    }

    private func loadRemoteDetailIfNeeded() async {
        guard let vehicleSN, canLoadRemoteDetail else { return }
        await model.refreshRideDetail(vehicleSN: vehicleSN, rideID: record.id)
    }
}

private struct RideDetailHero: View {
    var record: NinebotRideRecord
    var localRecord: NinebotRecordedRide?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.startedAt.map(formatRideDate) ?? "行程详情")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    if localRecord != nil {
                        Text("已关联本地轨迹")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.teslaGreen)
                    }
                }

                Spacer()

                if localRecord != nil {
                    Image(systemName: "map.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(formatDistance(record.mileage))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("里程")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            if !metrics.isEmpty {
                LazyVGrid(
                    columns: gridColumns,
                    spacing: 10
                ) {
                    ForEach(metrics) { metric in
                        BasicInfoTile(title: metric.title, value: metric.value, systemImage: metric.systemImage)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }

    private var gridColumns: [GridItem] {
        if metrics.count <= 1 {
            return [GridItem(.flexible(), spacing: 10)]
        }
        return [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var metrics: [RideDisplayMetric] {
        var result: [RideDisplayMetric] = [
            record.speed.map { RideDisplayMetric(title: "接口最高速度", value: formatSpeed($0), systemImage: "speedometer") },
            record.energy.map { RideDisplayMetric(title: "能耗", value: formatEnergyWh($0), systemImage: "bolt.horizontal.fill") },
            record.usedElectricity.map { RideDisplayMetric(title: "用电", value: formatPercent($0), systemImage: "powerplug.fill") },
            record.durationMinutes.map { RideDisplayMetric(title: "时长", value: formatDuration($0), systemImage: "timer") }
        ].compactMap { $0 }

        if let localRecord {
            result.append(contentsOf: [
                RideDisplayMetric(title: "本地极速", value: formatSpeed(localRecord.maxSpeedKmh), systemImage: "gauge.with.dots.needle.67percent"),
                RideDisplayMetric(title: "最大 G", value: formatAccelerationG(localRecord.maxAccelerationG), systemImage: "bolt.circle.fill"),
                RideDisplayMetric(title: "轨迹点", value: "\(localRecord.points.count) 个", systemImage: "point.3.connected.trianglepath.dotted")
            ])
        }

        return result
    }
}

private struct RideTrackExperiencePanel: View {
    var title: String
    var sourceDescription: String
    var points: [TrackSpeedPoint]
    var startedAt: Date?
    var endedAt: Date?
    var speedEstimationDurationSeconds: TimeInterval?
    var distanceText: String?

    @State private var cameraPosition: MapCameraPosition
    @State private var startAddress: String?
    @State private var endAddress: String?
    @State private var isResolvingAddresses = false
    @State private var showsPlaybackVehicle = false
    @State private var isPlaying = false
    @State private var playbackProgress: Double = 0
    @State private var playbackTask: Task<Void, Never>?

    init(
        title: String,
        sourceDescription: String,
        points: [TrackSpeedPoint],
        startedAt: Date?,
        endedAt: Date?,
        speedEstimationDurationSeconds: TimeInterval? = nil,
        distanceText: String? = nil
    ) {
        self.title = title
        self.sourceDescription = sourceDescription
        self.points = points
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.speedEstimationDurationSeconds = speedEstimationDurationSeconds
        self.distanceText = distanceText
        _cameraPosition = State(initialValue: .region(Self.region(for: points.map(\.coordinate))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(sourceDescription)
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                if let distanceText {
                    Text(distanceText)
                        .font(.headline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                }
            }

            ZStack(alignment: .bottomTrailing) {
                Map(position: $cameraPosition) {
                    ForEach(speedSegments) { segment in
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.color.opacity(showsPlaybackVehicle ? 0.32 : 1), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }

                    if showsPlaybackVehicle {
                        ForEach(playedSpeedSegments) { segment in
                            MapPolyline(coordinates: segment.coordinates)
                                .stroke(segment.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        }
                    }

                    if let firstPoint = renderedPoints.first {
                        Marker("起点", systemImage: "flag.fill", coordinate: firstPoint.coordinate)
                            .tint(.green)
                    }
                    if let lastPoint = renderedPoints.last, renderedPoints.count > 1 {
                        Marker("终点", systemImage: "flag.checkered", coordinate: lastPoint.coordinate)
                            .tint(.red)
                    }
                    if let maxSpeedPoint {
                        Annotation("最快", coordinate: maxSpeedPoint.coordinate) {
                            TrackMaxSpeedBadge(speed: maxSpeedPoint.speedKmh)
                        }
                    }
                    if showsPlaybackVehicle, let playbackCoordinate {
                        Annotation("电瓶车回放", coordinate: playbackCoordinate) {
                            RidePlaybackVehicleMarker(speed: playbackSpeed)
                        }
                    }
                }

                if showsPlaybackVehicle {
                    Text(playbackTimestampText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(10)
                }
            }
            .frame(height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.teslaHairline, lineWidth: 1)
            }

            TrackSpeedLegend()
            Text(speedColorDescription)
                .font(.caption2)
                .foregroundStyle(Color.teslaSecondaryText)

            RideEndpointAddressSection(
                startAddress: startAddress ?? fallbackAddress(for: renderedPoints.first?.coordinate),
                endAddress: endAddress ?? fallbackAddress(for: renderedPoints.last?.coordinate),
                startedAt: startedAt,
                endedAt: endedAt,
                isResolving: isResolvingAddresses
            )

            if canPlayback {
                playbackControls
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
        .task(id: endpointLookupKey) {
            await resolveEndpointAddresses()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private var renderedPoints: [TrackSpeedPoint] {
        guard !hasSourcePointSpeeds,
              let speedEstimationDurationSeconds,
              speedEstimationDurationSeconds > 1 else {
            return points
        }
        return estimatedTrackSpeedPoints(from: points, durationSeconds: speedEstimationDurationSeconds) ?? points
    }

    private var hasSourcePointSpeeds: Bool {
        points.contains { $0.speedKmh != nil }
    }

    private var hasEstimatedPointSpeeds: Bool {
        !hasSourcePointSpeeds && renderedPoints.contains { $0.speedKmh != nil }
    }

    private var speedColorDescription: String {
        if hasSourcePointSpeeds {
            return "路线根据九号云返回的逐点速度着色；回放时会高亮已骑行的路段。"
        }
        if hasEstimatedPointSpeeds {
            return "九号云未提供逐点速度，已按定位点间距和行程时长估算速度颜色。"
        }
        return "本次行程没有可用于估算的速度或时长数据，路线以默认绿色显示。"
    }

    private var speedSegments: [TrackSpeedSegment] {
        makeSpeedTrackSegments(from: renderedPoints)
    }

    private var maxSpeedPoint: TrackSpeedPoint? {
        bestSpeedTrackPoint(from: renderedPoints)
    }

    private var canPlayback: Bool {
        renderedPoints.count > 1
    }

    private var endpointLookupKey: String {
        guard let first = renderedPoints.first?.coordinate, let last = renderedPoints.last?.coordinate else {
            return "no-endpoints"
        }
        return String(format: "%.5f,%.5f|%.5f,%.5f", first.latitude, first.longitude, last.latitude, last.longitude)
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("轨迹回放", systemImage: "play.rectangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(playbackSpeedLabel)
                        .font(.caption2)
                    Text(playbackSpeed.map(formatSpeed) ?? "-- km/h")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(Color.teslaSecondaryText)
            }

            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    Label(
                        isPlaying ? "暂停" : (playbackProgress >= 0.999 ? "重播" : "播放"),
                        systemImage: isPlaying ? "pause.fill" : (playbackProgress >= 0.999 ? "arrow.counterclockwise" : "play.fill")
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.teslaGreen)
                .accessibilityLabel(isPlaying ? "暂停轨迹回放" : "开始轨迹回放")

                Button {
                    replayFromStart()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(Color.teslaGreen)
                .accessibilityLabel("从起点重新回放")

                Slider(
                    value: Binding(
                        get: { playbackProgress },
                        set: { newValue in
                            stopPlayback()
                            showsPlaybackVehicle = true
                            playbackProgress = newValue
                        }
                    ),
                    in: 0...1
                )
                .tint(Color.teslaGreen)
                .accessibilityLabel("轨迹回放进度")
            }
        }
        .padding(12)
        .background(Color.teslaPageBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var playbackCoordinate: CLLocationCoordinate2D? {
        guard renderedPoints.count > 1 else { return renderedPoints.first?.coordinate }
        let rawIndex = Double(renderedPoints.count - 1) * playbackProgress
        let lowerIndex = min(max(Int(rawIndex.rounded(.down)), 0), renderedPoints.count - 2)
        let progressWithinSegment = rawIndex - Double(lowerIndex)
        return interpolate(
            from: renderedPoints[lowerIndex].coordinate,
            to: renderedPoints[lowerIndex + 1].coordinate,
            progress: progressWithinSegment
        )
    }

    private var playbackSpeed: Double? {
        guard !renderedPoints.isEmpty else { return nil }
        let index = min(max(Int((Double(renderedPoints.count - 1) * playbackProgress).rounded()), 0), renderedPoints.count - 1)
        return renderedPoints[index].speedKmh
    }

    private var playbackSpeedLabel: String {
        hasEstimatedPointSpeeds ? "估算速度" : "当前速度"
    }

    private var playedSpeedSegments: [TrackSpeedSegment] {
        guard showsPlaybackVehicle, renderedPoints.count > 1, let playbackCoordinate else { return [] }
        let rawIndex = Double(renderedPoints.count - 1) * playbackProgress
        let fullSegmentCount = min(max(Int(rawIndex.rounded(.down)), 0), renderedPoints.count - 1)
        var playedPoints = Array(renderedPoints.prefix(fullSegmentCount + 1))

        if fullSegmentCount < renderedPoints.count - 1,
           playbackProgress > 0,
           !coordinatesMatch(playedPoints.last?.coordinate, playbackCoordinate) {
            let source = renderedPoints[fullSegmentCount]
            playedPoints.append(
                TrackSpeedPoint(
                    id: "playback-\(fullSegmentCount)",
                    coordinate: playbackCoordinate,
                    speedKmh: source.speedKmh
                )
            )
        }
        return makeSpeedTrackSegments(from: playedPoints)
    }

    private var playbackTimestampText: String {
        guard let startedAt else { return "回放中" }
        guard let endedAt else { return formatDate(startedAt) }
        let duration = max(endedAt.timeIntervalSince(startedAt), 0)
        return formatDate(startedAt.addingTimeInterval(duration * playbackProgress))
    }

    private func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func replayFromStart() {
        stopPlayback()
        playbackProgress = 0
        showsPlaybackVehicle = true
        startPlayback()
    }

    private func startPlayback() {
        guard canPlayback else { return }
        if playbackProgress >= 0.999 {
            playbackProgress = 0
        }
        showsPlaybackVehicle = true
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { @MainActor in
            // A 12-second preview keeps a full trip understandable while remaining interruptible.
            let playbackDuration: Double = 12
            let frameInterval: Double = 1.0 / 30.0
            while !Task.isCancelled && isPlaying && playbackProgress < 1 {
                try? await Task.sleep(nanoseconds: 33_333_333)
                guard !Task.isCancelled, isPlaying else { break }
                playbackProgress = min(playbackProgress + frameInterval / playbackDuration, 1)
            }
            if playbackProgress >= 1 {
                isPlaying = false
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func resolveEndpointAddresses() async {
        guard let first = renderedPoints.first?.coordinate, let last = renderedPoints.last?.coordinate else { return }
        isResolvingAddresses = true
        defer { isResolvingAddresses = false }

        async let resolvedStart = Self.reverseGeocodedAddress(for: first)
        async let resolvedEnd = Self.reverseGeocodedAddress(for: last)
        let (start, end) = await (resolvedStart, resolvedEnd)
        guard !Task.isCancelled else { return }
        startAddress = start
        endAddress = end
    }

    private func fallbackAddress(for coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "暂无定位地址" }
        return String(format: "位置 %.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func reverseGeocodedAddress(for coordinate: CLLocationCoordinate2D) async -> String? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            let parts = [
                placemark.name,
                placemark.thoroughfare,
                placemark.subThoroughfare,
                placemark.subLocality,
                placemark.locality,
                placemark.administrativeArea
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, part in
                if !result.contains(part) { result.append(part) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        } catch {
            return nil
        }
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            )
        }

        let minLatitude = coordinates.map(\.latitude).min() ?? coordinates[0].latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? coordinates[0].latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? coordinates[0].longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? coordinates[0].longitude
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.5, 0.006),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.5, 0.006)
            )
        )
    }
}

private struct RideEndpointAddressSection: View {
    var startAddress: String
    var endAddress: String
    var startedAt: Date?
    var endedAt: Date?
    var isResolving: Bool

    var body: some View {
        VStack(spacing: 0) {
            endpointRow(
                title: "起点",
                address: startAddress,
                time: startedAt,
                color: .green,
                systemImage: "play.fill"
            )

            Divider()
                .padding(.leading, 36)

            endpointRow(
                title: "终点",
                address: endAddress,
                time: endedAt,
                color: .red,
                systemImage: "stop.fill"
            )
        }
        .padding(.horizontal, 12)
        .background(Color.teslaPageBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("行程起点和终点地址")
    }

    private func endpointRow(
        title: String,
        address: String,
        time: Date?,
        color: Color,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                    if isResolving && address.hasPrefix("位置 ") {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                Text(address)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(2)
                Text(time.map(formatDate) ?? "时间未知")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}

private struct RidePlaybackVehicleMarker: View {
    var speed: Double?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "scooter")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.teslaGreen)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(.white, lineWidth: 2)
                }
                .shadow(color: Color.black.opacity(0.28), radius: 7, x: 0, y: 3)
            if let speed {
                Text(String(format: "%.0f", speed))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
        }
        .accessibilityLabel("电瓶车回放位置，速度 \(formatSpeed(speed))")
    }
}

private func interpolate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    progress: Double
) -> CLLocationCoordinate2D {
    let clampedProgress = min(max(progress, 0), 1)
    return CLLocationCoordinate2D(
        latitude: start.latitude + (end.latitude - start.latitude) * clampedProgress,
        longitude: start.longitude + (end.longitude - start.longitude) * clampedProgress
    )
}

private func coordinatesMatch(_ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.latitude - rhs.latitude) < 0.0000001
        && abs(lhs.longitude - rhs.longitude) < 0.0000001
}

private struct TrackSpeedPoint: Identifiable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var speedKmh: Double?
}

private struct TrackSpeedSegment: Identifiable {
    var id: String
    var coordinates: [CLLocationCoordinate2D]
    var speedKmh: Double?

    var color: Color {
        speedTrackColor(speedKmh)
    }
}

private struct TrackMaxSpeedBadge: View {
    var speed: Double?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.caption2.weight(.bold))
            Text(formatSpeed(speed))
                .font(.caption2.monospacedDigit().weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.red)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 4)
    }
}

private struct TrackSpeedLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("速度颜色", systemImage: "speedometer")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)

            HStack(spacing: 8) {
                legendItem(color: .blue, title: "0–10")
                legendItem(color: .cyan, title: "10–25")
                legendItem(color: Color.teslaGreen, title: "25–40")
                legendItem(color: .orange, title: "40–55")
                legendItem(color: .red, title: "55+")
                Spacer(minLength: 0)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color.teslaSecondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("路线速度颜色：每小时 0 到 10 公里蓝色，10 到 25 公里青色，25 到 40 公里绿色，40 到 55 公里橙色，55 公里以上红色")
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 3) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 4)
            Text(title)
        }
    }
}

private extension NinebotRecordedRide {
    var coordinates: [CLLocationCoordinate2D] {
        trackCoordinates
    }

    var speedTrackPoints: [TrackSpeedPoint] {
        points
            .sorted { $0.date < $1.date }
            .filter {
                (-90...90).contains($0.latitude)
                    && (-180...180).contains($0.longitude)
                    && (($0.horizontalAccuracy ?? 0) <= 120)
            }
            .enumerated()
            .map { index, point in
                TrackSpeedPoint(
                    id: point.id.isEmpty ? "local-\(index)" : point.id,
                    coordinate: NinebotCoordinateTransform.mapKitCoordinate(latitude: point.latitude, longitude: point.longitude),
                    speedKmh: point.speedKmh
                )
            }
    }

    var speedTrackCoordinates: [CLLocationCoordinate2D] {
        speedTrackPoints.map(\.coordinate)
    }

    var speedTrackSegments: [TrackSpeedSegment] {
        makeSpeedTrackSegments(from: speedTrackPoints)
    }

    var maxSpeedTrackPoint: TrackSpeedPoint? {
        bestSpeedTrackPoint(from: speedTrackPoints)
    }
}

private func estimatedTrackSpeedPoints(
    from points: [TrackSpeedPoint],
    durationSeconds: TimeInterval
) -> [TrackSpeedPoint]? {
    guard points.count > 1, durationSeconds > 1 else { return nil }
    let sampleInterval = durationSeconds / Double(points.count - 1)
    guard sampleInterval > 0 else { return nil }

    let segmentSpeeds = zip(points, points.dropFirst()).map { start, end -> Double in
        let distance = CLLocation(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)
            .distance(from: CLLocation(latitude: end.coordinate.latitude, longitude: end.coordinate.longitude))
        // A point stream sampled at roughly even intervals can provide a useful
        // fallback for route colours when Ninebot omits raw point speeds.
        return min(max(distance / sampleInterval * 3.6, 0), 160)
    }
    guard segmentSpeeds.contains(where: { $0 > 0.05 }) else { return nil }

    return points.enumerated().map { index, point in
        let speed: Double
        switch index {
        case 0:
            speed = segmentSpeeds[0]
        case points.count - 1:
            speed = segmentSpeeds[segmentSpeeds.count - 1]
        default:
            speed = (segmentSpeeds[index - 1] + segmentSpeeds[index]) / 2
        }
        return TrackSpeedPoint(id: point.id, coordinate: point.coordinate, speedKmh: speed)
    }
}

private func makeSpeedTrackSegments(from points: [TrackSpeedPoint]) -> [TrackSpeedSegment] {
    guard points.count > 1 else { return [] }

    return (0..<(points.count - 1)).map { index in
        let start = points[index]
        let end = points[index + 1]
        let availableSpeeds = [start.speedKmh, end.speedKmh].compactMap { $0 }
        let speed = availableSpeeds.isEmpty
            ? nil
            : availableSpeeds.reduce(0, +) / Double(availableSpeeds.count)
        return TrackSpeedSegment(
            id: "\(start.id)-\(end.id)-\(index)",
            coordinates: [start.coordinate, end.coordinate],
            speedKmh: speed
        )
    }
}

private func bestSpeedTrackPoint(from points: [TrackSpeedPoint]) -> TrackSpeedPoint? {
    points
        .filter { ($0.speedKmh ?? 0) > 0.5 }
        .max { ($0.speedKmh ?? 0) < ($1.speedKmh ?? 0) }
}

private func speedTrackColor(_ speed: Double?) -> Color {
    guard let speed else { return Color.teslaGreen.opacity(0.78) }
    switch speed {
    case ..<10:
        return .blue
    case ..<25:
        return .cyan
    case ..<40:
        return Color.teslaGreen
    case ..<55:
        return .orange
    default:
        return .red
    }
}

private struct RideMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RawFieldSection: View {
    var title: String
    var fields: [String: JSONValue]?
    @State private var didCopy = false

    var body: some View {
        DisclosureGroup {
            if let fields, !fields.isEmpty {
                let rows = fields.sorted { lhs, rhs in
                    lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }

                VStack(spacing: 0) {
                    ForEach(rows, id: \.key) { key, value in
                        RawFieldRow(key: key, value: value.displayText)
                    }
                }
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if didCopy {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                } else if let copyText {
                    Button {
                        copyRawText(copyText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var copyText: String? {
        guard let fields, !fields.isEmpty else { return nil }
        return formattedJSON(.object(fields))
    }

    private func copyRawText(_ text: String) {
        UIPasteboard.general.string = text
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            didCopy = false
        }
    }
}

private struct RawJSONSection: View {
    var title: String
    var value: JSONValue?
    @State private var didCopy = false

    var body: some View {
        DisclosureGroup {
            if let value {
                if let object = value.objectValue, !object.isEmpty {
                    let rows = object.sorted { lhs, rhs in
                        lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                    }

                    VStack(spacing: 0) {
                        ForEach(rows, id: \.key) { key, value in
                            RawFieldRow(key: key, value: value.displayText)
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(value.displayText)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.teslaPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                }
            } else {
                Text("详情返回后会显示完整字段")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if didCopy {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                } else if let copyText {
                    Button {
                        copyRawText(copyText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var copyText: String? {
        guard let value else { return nil }
        return formattedJSON(value)
    }

    private func copyRawText(_ text: String) {
        UIPasteboard.general.string = text
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            didCopy = false
        }
    }
}

private struct RawFieldRow: View {
    var key: String
    var value: String

    var body: some View {
        let displayName = friendlyRawFieldName(key)

        VStack(alignment: .leading, spacing: 5) {
            Text(displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            if displayName != key {
                Text(key)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Text(value.isEmpty ? "--" : value)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct RawPayloadCopyPanel: View {
    var snapshot: NinebotVehicleSnapshot
    @Binding var copiedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("原始返回值")
                        .font(.headline)
                    Text("复制车辆、状态、行程接口的完整 JSON，方便排查新字段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }

            Button {
                UIPasteboard.general.string = fullPayloadText
                copiedMessage = "已复制完整返回值"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    copiedMessage = nil
                }
            } label: {
                Label("复制完整返回值", systemImage: "doc.on.doc.fill")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fullPayloadText: String {
        formattedJSON(
            .object([
                "vehicle": .object(snapshot.vehicle.raw ?? [:]),
                "status": .object(snapshot.state.rawStatus ?? [:]),
                "travel": .object(snapshot.state.rawTravel ?? [:])
            ])
        )
    }
}

extension Color {
    static let teslaPageBackground = dynamic(
        light: UIColor(red: 0.945, green: 0.952, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.025, green: 0.029, blue: 0.035, alpha: 1)
    )
    static let teslaCardBackground = dynamic(
        light: UIColor(red: 0.995, green: 0.995, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.075, green: 0.08, blue: 0.092, alpha: 1)
    )
    static let teslaControlBackground = dynamic(
        light: UIColor(red: 0.91, green: 0.925, blue: 0.94, alpha: 1),
        dark: UIColor(red: 0.125, green: 0.135, blue: 0.152, alpha: 1)
    )
    static let teslaPrimaryText = dynamic(
        light: UIColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.95, blue: 0.965, alpha: 1)
    )
    static let teslaSecondaryText = dynamic(
        light: UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1),
        dark: UIColor(red: 0.62, green: 0.65, blue: 0.69, alpha: 1)
    )
    static let teslaGreen = dynamic(
        light: UIColor(red: 0.13, green: 0.82, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.93, blue: 0.38, alpha: 1)
    )
    static let teslaActionThumb = dynamic(
        light: UIColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.82, blue: 0.28, alpha: 1)
    )
    static let teslaHairline = dynamic(
        light: UIColor(red: 0, green: 0, blue: 0, alpha: 0.06),
        dark: UIColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct NinePlusCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat? = nil
    var shadowOpacity: Double = 0.05

    func body(content: Content) -> some View {
        let card = content
            .background(Color.teslaCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.teslaHairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 14, x: 0, y: 8)

        if let padding {
            card.padding(padding)
        } else {
            card
        }
    }
}

extension View {
    func ninePlusCard(
        cornerRadius: CGFloat = 24,
        padding: CGFloat? = nil,
        shadowOpacity: Double = 0.05
    ) -> some View {
        modifier(NinePlusCardStyle(cornerRadius: cornerRadius, padding: padding, shadowOpacity: shadowOpacity))
    }
}

private struct VehicleRow: View {
    var snapshot: NinebotVehicleSnapshot
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.vehicle.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(snapshot.state.enduranceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(snapshot.state.batteryText)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(batteryTextColor(snapshot.state))
                    Text(snapshot.state.primaryStatusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(snapshot.state))
                        .lineLimit(1)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.teslaGreen : Color(.tertiaryLabel))
            }
            .padding(12)
            .background(Color.teslaCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func vehicleCoordinate(_ state: NinebotVehicleState) -> CLLocationCoordinate2D? {
    guard let latitude = state.latitude,
          let longitude = state.longitude,
          (-90...90).contains(latitude),
          (-180...180).contains(longitude) else {
        return nil
    }

    return mapKitCoordinate(latitude: latitude, longitude: longitude)
}

private func mapKitCoordinate(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
    NinebotCoordinateTransform.mapKitCoordinate(latitude: latitude, longitude: longitude)
}

private func formatDistance(_ value: Double?) -> String {
    formatNumber(value, unit: " km", maximumFractionDigits: 1)
}

private func formatDistanceNumber(_ value: Double?) -> String {
    formatNumber(value, unit: "", maximumFractionDigits: 1)
}

private func formatEnergyWh(_ value: Double?) -> String {
    formatNumber(value, unit: " Wh", maximumFractionDigits: 0)
}

private func formatPercent(_ value: Double?) -> String {
    formatNumber(value, unit: "%", maximumFractionDigits: 1)
}

private func formatSpeed(_ value: Double?) -> String {
    formatNumber(value, unit: " km/h", maximumFractionDigits: 1)
}

private func formatAccelerationG(_ value: Double?) -> String {
    formatNumber(value, unit: " G", maximumFractionDigits: 2, minimumFractionDigits: 2)
}

private func shortTrendValue(_ value: Double) -> String {
    if value >= 100 {
        return formatNumber(value, unit: "", maximumFractionDigits: 0)
    }
    if value >= 10 {
        return formatNumber(value, unit: "", maximumFractionDigits: 1)
    }
    return formatNumber(value, unit: "", maximumFractionDigits: 1)
}

private func formatDuration(_ minutes: Double?) -> String {
    guard let minutes else { return "--" }
    if minutes >= 60 {
        return formatNumber(minutes / 60, unit: " 小时", maximumFractionDigits: 1)
    }
    return formatNumber(minutes, unit: " 分钟", maximumFractionDigits: 0)
}

private func formatRideDate(_ date: Date) -> String {
    formatDate(date)
}

private func formattedJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return value.displayText
    }
    return text
}

private func formatNumber(
    _ value: Double?,
    unit: String,
    maximumFractionDigits: Int = 6,
    minimumFractionDigits: Int = 0
) -> String {
    guard let value else { return "--\(unit)" }
    let formatter = NumberFormatter()
    formatter.maximumFractionDigits = maximumFractionDigits
    formatter.minimumFractionDigits = minimumFractionDigits
    let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    return "\(text)\(unit)"
}

private func boolText(_ value: Bool?, trueText: String, falseText: String) -> String {
    guard let value else { return "未知" }
    return value ? trueText : falseText
}

private func coordinateText(_ latitude: Double?, _ longitude: Double?) -> String {
    guard let latitude, let longitude else { return "--" }
    return "\(formatCoordinate(latitude)), \(formatCoordinate(longitude))"
}

private func formatCoordinate(_ value: Double?) -> String {
    formatNumber(value, unit: "", maximumFractionDigits: 8)
}

private func healthColor(_ level: NinebotVehicleHealthLevel) -> Color {
    switch level {
    case .good:
        return Color.teslaGreen
    case .attention:
        return .orange
    case .critical:
        return .red
    case .charging:
        return Color.teslaGreen
    case .unknown:
        return .secondary
    }
}

private func statusColor(_ state: NinebotVehicleState) -> Color {
    healthColor(state.health.level)
}

private func statusSystemImage(_ state: NinebotVehicleState) -> String {
    state.health.systemImage
}

private func compactVehicleStatusText(_ state: NinebotVehicleState) -> String {
    if state.isFullyCharged {
        return "已充满"
    }
    if state.isCharging == true {
        return "充电中"
    }
    if state.isPoweredOn == true {
        return "已上电"
    }
    if state.isLocked == true {
        return "已上锁"
    }
    if state.isLocked == false {
        return "未上锁"
    }
    return state.primaryStatusText
}

private func batteryTextColor(_ state: NinebotVehicleState) -> Color {
    if state.isFullyCharged { return Color.teslaGreen }
    if state.isCharging == true { return Color.teslaGreen }
    guard let battery = state.battery else { return .primary }
    if battery < 15 { return .red }
    if battery < 50 { return .orange }
    return .primary
}

private func friendlyRawFieldName(_ key: String) -> String {
    let names: [String: String] = [
        "ai_estimate_mileage": "AI 预估续航",
        "aiEstimateMileage": "AI 预估续航",
        "ai_estimated_mileage": "AI 预估续航",
        "aiEstimatedMileage": "AI 预估续航",
        "and_mac": "Android MAC",
        "battery": "电量",
        "battery_exist": "电池存在",
        "battery_list": "电池列表",
        "batteryList": "电池列表",
        "battery_main": "主电池",
        "batteryMain": "主电池",
        "battery_voltage": "电池电压",
        "batteryVoltage": "电池电压",
        "battery_vol": "电池电压",
        "batteryVol": "电池电压",
        "battery_temperature": "电池温度",
        "batteryTemperature": "电池温度",
        "battery_temp": "电池温度",
        "batteryTemp": "电池温度",
        "barrel_lock_status": "座桶锁状态",
        "bat_voltage": "电池电压",
        "batVoltage": "电池电压",
        "bat_temperature": "电池温度",
        "batTemperature": "电池温度",
        "bat_temp": "电池温度",
        "batTemp": "电池温度",
        "batt_voltage": "电池电压",
        "battVoltage": "电池电压",
        "batt_temperature": "电池温度",
        "battTemperature": "电池温度",
        "batt_temp": "电池温度",
        "battTemp": "电池温度",
        "bms": "电池管理",
        "bms_cycle": "循环次数",
        "bmsCycle": "循环次数",
        "bmsInfo": "电池管理",
        "bms_info": "电池管理",
        "bms_volt": "电池电压",
        "bmsVolt": "电池电压",
        "bms_voltage": "电池电压",
        "bmsVoltage": "电池电压",
        "bms_temperature": "电池温度",
        "bmsTemperature": "电池温度",
        "bms_temp": "电池温度",
        "bmsTemp": "电池温度",
        "buck": "座桶",
        "business_uid": "业务用户 ID",
        "businessUID": "业务用户 ID",
        "begin_time": "开始时间",
        "beginTime": "开始时间",
        "charging": "充电状态",
        "charging_power": "充电功率",
        "chargingPower": "充电功率",
        "chargingState": "充电状态",
        "charging_protection": "充电保护",
        "color": "颜色",
        "cost_time": "用时",
        "costTime": "用时",
        "create_time": "创建时间",
        "createTime": "创建时间",
        "device_name": "设备名称",
        "distance": "里程",
        "day_total_mileage": "当日总里程",
        "detail": "每日里程",
        "dump_energy": "剩余电量",
        "dumpEnergy": "剩余电量",
        "duration": "时长",
        "ec": "能耗",
        "end_time": "结束时间",
        "endTime": "结束时间",
        "estimateMileage": "预估续航",
        "estimate_mileage": "预估续航",
        "id": "ID",
        "image": "车辆图片",
        "last_ec": "最近能耗",
        "last_mileages": "最近里程",
        "last_used_electricity": "最近用电",
        "lat": "纬度",
        "latitude": "纬度",
        "left_mileage_user_choose": "剩余里程选择",
        "list": "行程列表",
        "loc": "定位信息",
        "locationDesc": "位置描述",
        "locationInfo": "定位信息",
        "lock": "锁车状态",
        "lon": "经度",
        "longitude": "经度",
        "mileages": "里程",
        "mileage": "里程",
        "month": "月份",
        "model": "车型",
        "name": "名称",
        "pwr": "电源状态",
        "powerStatus": "电源状态",
        "precise_estimate_mileage": "精确预估续航",
        "precise_mileage_user_choose": "精确里程选择",
        "remainChargeTime": "剩余充电时间",
        "remain_charge_time": "剩余充电时间",
        "remain_charge_timestamp": "剩余充电时间戳",
        "remainingChargeTime": "剩余充电时间",
        "speed": "速度",
        "sn": "SN",
        "total_mileage": "总里程",
        "totalMileage": "总里程",
        "total_mileages": "本月里程",
        "times": "骑行次数",
        "track": "接口轨迹",
        "trail": "接口轨迹",
        "trial": "接口轨迹",
        "travel_id": "行程 ID",
        "used_electricity": "已用电量",
        "vehicle_name": "车辆名称",
        "vehicle_vin": "VIN",
        "vehicleVin": "VIN",
        "vin": "VIN",
        "VIN": "VIN",
        "volt": "电压",
        "voltage": "电压",
        "temp": "温度",
        "temperature": "温度",
        "wnumber": "车辆编号"
    ]
    return names[key] ?? key
}

private struct EmptyDashboardView: View {
    var hasConfiguration: Bool
    var isLoading: Bool = false
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: hasConfiguration ? "antenna.radiowaves.left.and.right.slash" : "link.badge.plus")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(hasConfiguration ? "暂无车辆数据" : "未配置代理")
                .font(.headline)

            Text(hasConfiguration ? "将优先显示上次缓存，并在回到前台时自动刷新车辆状态" : "到“我的”填写代理地址并登录后即可读取车辆")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if hasConfiguration {
                Button(action: onRetry) {
                    HStack(spacing: 7) {
                        if isLoading { ProgressView().tint(.white) }
                        Image(systemName: "arrow.clockwise")
                        Text(isLoading ? "正在刷新" : "点击重试")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.teslaGreen, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityHint("也支持在页面顶部下拉刷新")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 20)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct VehicleImage: View {
    var urlString: String?
    var sn: String?
    var size: CGFloat
    var showsBackground = true
    @State private var cachedImage: UIImage?

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            }

            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    case .failure:
                        fallbackImage
                    case .empty:
                        // 不再让 ProgressView 永久占据车辆区域；网络图片加载期间
                        // 先显示缓存或内置车辆图，避免用户看到空白主页。
                        fallbackImage
                    @unknown default:
                        fallbackImage
                    }
                }
            } else {
                fallbackImage
            }
        }
        .frame(width: size, height: size)
        .task(id: sn) {
            guard let sn, !sn.isEmpty else { return }
            guard let data = NinebotSharedStore().loadVehicleImageData(sn: sn),
                  let image = UIImage(data: data) else { return }
            cachedImage = image
        }
    }

    @ViewBuilder
    private var fallbackImage: some View {
        if let cachedImage {
            Image(uiImage: cachedImage)
                .resizable()
                .scaledToFit()
                .padding(6)
        } else {
            Image("LoginVehicle")
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
                .opacity(0.92)
        }
    }
}

private struct MetricView: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatteryGauge: View {
    var value: Int?

    var body: some View {
        Gauge(value: Double(value ?? 0), in: 0...100) {
            Text("电量")
        } currentValueLabel: {
            Text(value.map { "\($0)" } ?? "--")
                .font(.caption.weight(.bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(gaugeColor)
    }

    private var gaugeColor: Color {
        guard let value else { return .gray }
        if value < 20 { return .red }
        if value < 50 { return .orange }
        return Color.teslaGreen
    }
}

struct NinebotDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        NinebotDashboardView(model: NinebotViewModel())
    }
}
