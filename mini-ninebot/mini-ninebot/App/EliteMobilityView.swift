import SwiftUI
import MapKit

/// The primary app shell follows the supplied premium mobility reference: a
/// dark OLED canvas, four focused destinations, and electric-blue energy
/// signals. Existing data and vehicle-control services stay untouched.
struct EliteMobilityShell: View {
    @ObservedObject var model: NinebotViewModel

    @State private var selectedTab: EliteMobilityTab = .home
    @State private var showsSettings = false

    var body: some View {
        ZStack {
            Color.eliteBackground
                .ignoresSafeArea()

            Group {
                switch selectedTab {
                case .home:
                    NavigationStack {
                        EliteHomeView(
                            model: model,
                            onOpenRecords: { selectedTab = .records },
                            onOpenMap: { selectedTab = .map },
                            onOpenSettings: { showsSettings = true }
                        )
                        .toolbar(.hidden, for: .navigationBar)
                    }
                case .map:
                    NavigationStack {
                        NinebotSecurityView(model: model)
                            .navigationTitle("车辆位置")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(Color.eliteBackground, for: .navigationBar)
                    }
                case .charge:
                    EliteChargeView(model: model) {
                        selectedTab = .home
                    }
                case .records:
                    NavigationStack {
                        NinebotTripsTabView(model: model)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    NavigationLink {
                                        NinebotRecordingView(model: model)
                                    } label: {
                                        Image(systemName: "record.circle")
                                            .foregroundStyle(Color.elitePrimaryLight)
                                    }
                                    .accessibilityLabel("开始记录骑行")
                                }
                            }
                            .toolbarBackground(Color.teslaPageBackground, for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EliteTabBar(selectedTab: $selectedTab)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                NinebotSettingsView(model: model)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Color.eliteBackground, for: .navigationBar)
            }
        }
    }
}

private enum EliteMobilityTab: CaseIterable, Hashable {
    case home
    case map
    case charge
    case records

    var title: String {
        switch self {
        case .home: return "首页"
        case .map: return "地图"
        case .charge: return "充电"
        case .records: return "记录"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .map: return "location.fill"
        case .charge: return "bolt.batteryblock.fill"
        case .records: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
}

private struct EliteTabBar: View {
    @Binding var selectedTab: EliteMobilityTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EliteMobilityTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.24, extraBounce: 0.08)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            if selectedTab == tab {
                                Circle()
                                    .fill(Color.elitePrimary.opacity(0.18))
                                    .frame(width: 38, height: 38)
                                    .transition(.scale.combined(with: .opacity))
                            }

                            Image(systemName: tab.systemImage)
                                .font(.system(size: 18, weight: selectedTab == tab ? .bold : .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(selectedTab == tab ? Color.elitePrimaryLight : Color.eliteSecondaryText)
                        }
                        .frame(height: 38)

                        Text(tab.title)
                            .font(.system(size: 11, weight: selectedTab == tab ? .bold : .medium))
                            .foregroundStyle(selectedTab == tab ? Color.elitePrimaryLight : Color.eliteSecondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .background(Color.eliteBackground.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}

private struct EliteHomeView: View {
    @ObservedObject var model: NinebotViewModel
    var onOpenRecords: () -> Void
    var onOpenMap: () -> Void
    var onOpenSettings: () -> Void

    @State private var isShowingVehiclePicker = false
    @State private var pendingAction: NinebotVehicleAction?

    private var snapshot: NinebotVehicleSnapshot? {
        model.dashboard.primaryVehicle
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                EliteHomeHeader(
                    snapshot: snapshot,
                    isRefreshing: model.isLoading || model.isRefreshingDashboard,
                    onRefresh: { Task { await model.refreshDashboard() } },
                    onVehiclePicker: { isShowingVehiclePicker = true },
                    onOpenSettings: onOpenSettings
                )

                if let snapshot {
                    EliteVehicleStage(snapshot: snapshot)

                    if let message = model.latestVehicleActionMessage {
                        EliteVehicleActionFeedback(
                            message: message,
                            isError: model.isLatestVehicleActionError
                        )
                    }

                    EliteQuickControls(
                        activeAction: model.activeVehicleAction,
                        onAction: requestAction
                    )

                    HStack(alignment: .top, spacing: 12) {
                        NavigationLink {
                            EliteChargeDetailView(snapshot: snapshot)
                        } label: {
                            EliteBatteryCard(snapshot: snapshot)
                        }
                        .buttonStyle(.plain)

                        EliteLocationMapCard(
                            snapshot: snapshot,
                            address: model.resolvedAddressText(for: snapshot),
                            onOpenMap: onOpenMap
                        )
                    }

                    EliteStatusPair(snapshot: snapshot)
                    EliteRideSummaryCard(snapshot: snapshot, onOpenRecords: onOpenRecords)
                } else {
                    EliteEmptyVehicleCard(isRefreshing: model.isLoading) {
                        Task { await model.refreshDashboard() }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .background(Color.eliteBackground)
        .sheet(isPresented: $isShowingVehiclePicker) {
            EliteVehiclePicker(model: model)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(action.confirmationTitle),
                message: Text(action.confirmationMessage),
                primaryButton: .default(Text("确认")) { perform(action) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private func requestAction(_ action: NinebotVehicleAction) {
        if action.isDangerous {
            pendingAction = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: NinebotVehicleAction) {
        guard let sn = snapshot?.vehicle.sn else { return }
        Task { await model.perform(action, sn: sn) }
    }
}

private struct EliteHomeHeader: View {
    var snapshot: NinebotVehicleSnapshot?
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onVehiclePicker: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onRefresh) {
                ZStack {
                    Circle().fill(Color.eliteSurfaceHigh)
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "wave.3.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.elitePrimaryLight)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新车辆状态")

            Button(action: onVehiclePicker) {
                VStack(spacing: 1) {
                    Text(snapshot?.vehicle.name ?? "NinePlus")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.elitePrimaryText)
                        .lineLimit(1)
                    Text(isRefreshing ? "正在同步车辆数据" : "已连接 · \(snapshot?.vehicle.model ?? "等待车辆")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.eliteSecondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button(action: onOpenSettings) {
                ZStack {
                    Circle().fill(Color.eliteSurfaceHigh)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.elitePrimaryLight)
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开设置")
        }
        .padding(.top, 4)
    }
}

/// The supplied vehicle artwork treats 06:00 through 18:59 as daytime.
/// Keep this decision local and deterministic so a weather API sunrise value
/// cannot leave the dashboard on a night image after the app clock has passed
/// the morning handoff.
enum NinebotDaylight {
    static let dayStartHour = 6
    static let nightStartHour = 19

    static func isDay(at date: Date = Date()) -> Bool {
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: date)
        return (dayStartHour..<nightStartHour).contains(hour)
    }
}

private func eliteIsDay(at date: Date = Date()) -> Bool {
    NinebotDaylight.isDay(at: date)
}

private func eliteTeslaImageName(for state: NinebotVehicleState, isDay: Bool = eliteIsDay()) -> String {
    if state.isCharging == true {
        return isDay ? "EliteChargingVehicleDay" : "EliteChargingVehicle"
    }
    if state.isRideActive {
        return isDay ? "TeslaCybertruckRidingDay" : "TeslaCybertruckRiding"
    }
    return isDay ? "TeslaCybertruckParkedDay" : "TeslaCybertruckParked"
}

private struct EliteVehicleStage: View {
    var snapshot: NinebotVehicleSnapshot

    private var isCharging: Bool { snapshot.state.isCharging == true }
    private var isRideActive: Bool { snapshot.state.isRideActive }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let isDay = eliteIsDay(at: timeline.date)
            ZStack(alignment: .bottom) {
                Image(eliteTeslaImageName(for: snapshot.state, isDay: isDay))
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        LinearGradient(
                            colors: isDay
                                ? [Color.white.opacity(0.10), Color.clear, Color.black.opacity(0.25)]
                                : [Color.clear, Color.black.opacity(0.25), Color.black.opacity(0.78)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .clipped()

                EliteGridGlow().opacity(isDay ? 0.08 : 0.18)

                VStack(spacing: 0) {
                    HStack {
                        EliteStatusChip(
                            title: isCharging ? "正在充电" : (isRideActive ? "车辆正在行驶中" : snapshot.state.primaryStatusText),
                            systemImage: isCharging ? "bolt.fill" : (isRideActive ? "figure.outdoor.cycle" : (snapshot.state.isLocked == true ? "lock.fill" : "power"))
                        )
                        Spacer()
                        Text("更新于 \(eliteTime(snapshot.state.updatedAt))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                    Spacer(minLength: 0)

                    if !isCharging {
                        HStack(alignment: .bottom) {
                            if !isRideActive {
                                Text("车辆已停稳")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                            }

                            Spacer()

                            if isRideActive {
                                Text("D")
                                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.elitePrimaryLight)
                                    .frame(width: 25, height: 25)
                                    .accessibilityLabel("行驶挡位 D")
                            } else {
                                Image(systemName: "parkingsign.circle.fill")
                                    .font(.system(size: 25, weight: .semibold))
                                    .foregroundStyle(Color.elitePrimaryLight)
                            }
                        }
                        .padding(18)
                    }
                }
            }
        }
        .frame(height: 294)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .eliteCard(cornerRadius: 32, glow: true)
    }
}

private struct EliteGridGlow: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(
                    colors: [Color.elitePrimary.opacity(0.30), .clear],
                    center: .center,
                    startRadius: 6,
                    endRadius: proxy.size.width * 0.64
                )
                .offset(y: 58)

                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    for index in 0...8 {
                        let y = height * 0.58 + CGFloat(index) * 18
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    for index in 0...10 {
                        let x = width * CGFloat(index) / 10
                        path.move(to: CGPoint(x: width / 2, y: height * 0.45))
                        path.addLine(to: CGPoint(x: x, y: height))
                    }
                }
                .stroke(Color.elitePrimary.opacity(0.10), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EliteChargingPort: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: -8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.eliteSurfaceBright)
                .frame(width: 19, height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.elitePrimary.opacity(0.65), lineWidth: 1)
                }
            Capsule()
                .stroke(Color.elitePrimary.opacity(0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 36, height: 16)
                .rotationEffect(.degrees(-12))
        }
    }
}

private struct EliteQuickControls: View {
    var activeAction: NinebotVehicleAction?
    var onAction: (NinebotVehicleAction) -> Void

    private let actions: [NinebotVehicleAction] = [.bell, .engineStart, .engineStop, .openBucket]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(actions) { action in
                EliteControlButton(
                    title: action == .bell ? "寻车" : (action == .openBucket ? "打开座桶" : (action == .engineStart ? "启动" : "熄火")),
                    systemImage: action.systemImage,
                    isPrimary: action == .engineStart,
                    isLoading: activeAction == action,
                    action: { onAction(action) }
                )
            }
        }
        .disabled(activeAction != nil)
        .opacity(activeAction == nil ? 1 : 0.84)
    }
}

private struct EliteControlButton: View {
    var title: String
    var systemImage: String
    var isPrimary = false
    var isLoading: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isPrimary ? Color.elitePrimary : Color.elitePrimary.opacity(0.14))
                        .frame(width: 46, height: 46)
                    if isLoading {
                        ProgressView().tint(isPrimary ? .white : Color.elitePrimary)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isPrimary ? .white : Color.elitePrimary)
                    }
                }
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.elitePrimaryText)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.eliteSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.eliteOutline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct EliteVehicleActionFeedback: View {
    var message: String
    var isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isError ? Color.eliteError : Color.eliteSuccess)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background((isError ? Color.eliteError : Color.eliteSuccess).opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel(message)
    }
}

private struct EliteBatteryCard: View {
    var snapshot: NinebotVehicleSnapshot

    private var state: NinebotVehicleState { snapshot.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(state.isCharging == true ? "充电状态" : "电池状态", systemImage: state.isCharging == true ? "bolt.fill" : "battery.100percent")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.eliteSecondaryText)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(state.battery.map(String.init) ?? "--")
                    .font(.system(size: 35, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.elitePrimary)
                Text("%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.elitePrimaryText)
            }

            EliteEnergyProgressBar(fraction: state.batteryFraction, isCharging: state.isCharging == true)
                .frame(height: 10)

            Text(state.isCharging == true ? state.chargeSummaryText : state.enduranceText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.eliteSecondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
        .padding(16)
        .eliteCard(cornerRadius: 26, glow: state.isCharging == true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前电量")
        .accessibilityValue("\(Int((state.batteryFraction * 100).rounded()))%")
    }
}

private struct EliteEnergyProgressBar: View {
    var fraction: Double
    var isCharging: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.eliteTrack)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isCharging ? [Color.eliteSuccess, Color.elitePrimary] : [Color.eliteWarning, Color.elitePrimary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 5))
                    .shadow(color: (isCharging ? Color.eliteSuccess : Color.elitePrimary).opacity(0.32), radius: isCharging ? 8 : 4)
            }
        }
    }
}

private struct EliteStatusPair: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        HStack(spacing: 12) {
            EliteMetricTile(
                title: "车辆状态",
                value: snapshot.state.isRideActive ? "骑行状态" : (snapshot.state.isLocked == true ? "车辆已上锁" : (snapshot.state.isPoweredOn == true ? "已上电" : "待命")),
                caption: snapshot.state.isRideActive ? "车辆已解锁" : snapshot.state.lockText,
                systemImage: snapshot.state.isRideActive ? "figure.outdoor.cycle" : (snapshot.state.isLocked == true ? "lock.fill" : "power")
            )
            EliteMetricTile(
                title: snapshot.state.isRideActive ? "当前时速" : "本月里程",
                value: snapshot.state.isRideActive ? snapshot.state.currentSpeedText : snapshot.state.monthMileageText,
                caption: snapshot.state.isRideActive ? "实时状态" : "累计骑行",
                systemImage: snapshot.state.isRideActive ? "gauge.with.dots.needle.67percent" : "road.lanes"
            )
        }
    }
}

private struct EliteMetricTile: View {
    var title: String
    var value: String
    var caption: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.elitePrimaryLight)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.eliteSecondaryText)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.elitePrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.eliteSecondaryText.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .padding(18)
        .eliteCard(cornerRadius: 26)
    }
}

private struct EliteLocationMapCard: View {
    var snapshot: NinebotVehicleSnapshot
    var address: String?
    var onOpenMap: () -> Void

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = snapshot.state.latitude, let longitude = snapshot.state.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var region: MKCoordinateRegion {
        guard let coordinate else { return MKCoordinateRegion() }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 900, longitudinalMeters: 900)
    }

    var body: some View {
        Button(action: onOpenMap) {
            ZStack(alignment: .bottomLeading) {
                if let coordinate {
                    Map(initialPosition: .region(region), interactionModes: []) {
                        Marker("车辆位置", coordinate: coordinate)
                            .tint(Color.elitePrimary)
                    }
                    .allowsHitTesting(false)
                } else {
                    LinearGradient(
                        colors: [Color.elitePrimary.opacity(0.20), Color.eliteSurfaceHigh],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "map")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Color.elitePrimary.opacity(0.78))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                LinearGradient(colors: [.clear, Color.black.opacity(0.68)], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Label("车辆位置 · 地图", systemImage: "location.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                    Text(address ?? snapshot.state.locationText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
                .padding(13)
            }
            .frame(maxWidth: .infinity, minHeight: 176)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.eliteOutline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("车辆位置地图")
    }
}

private struct EliteRideSummaryCard: View {
    var snapshot: NinebotVehicleSnapshot
    var onOpenRecords: () -> Void

    var body: some View {
        Button(action: onOpenRecords) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("骑行记录")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.elitePrimaryText)
                    Text("最近一次 \(snapshot.state.lastRideSummaryText)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.eliteSecondaryText)
                }
                Spacer()
                HStack(spacing: 8) {
                    Text("查看全部")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(Color.elitePrimaryLight)
            }
            .padding(18)
            .eliteCard(cornerRadius: 24)
        }
        .buttonStyle(.plain)
    }
}

private struct EliteEmptyVehicleCard: View {
    var isRefreshing: Bool
    var onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.rear.fill")
                .font(.system(size: 45, weight: .medium))
                .foregroundStyle(Color.elitePrimaryLight)
            Text("暂未获取到车辆")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.elitePrimaryText)
            Text("请检查服务连接后，重新同步车辆数据。")
                .font(.subheadline)
                .foregroundStyle(Color.eliteSecondaryText)
            Button(action: onRefresh) {
                Label(isRefreshing ? "正在同步" : "重新同步", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.elitePrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .eliteCard(cornerRadius: 30)
    }
}

private struct EliteVehiclePicker: View {
    @ObservedObject var model: NinebotViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选择车辆")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.elitePrimaryText)

            ForEach(model.dashboard.vehicles) { vehicle in
                Button {
                    model.selectVehicle(sn: vehicle.vehicle.sn)
                    dismiss()
                } label: {
                    HStack(spacing: 13) {
                        Image(eliteTeslaImageName(for: vehicle.state, isDay: eliteIsDay()))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vehicle.vehicle.name)
                                .font(.headline)
                                .foregroundStyle(Color.elitePrimaryText)
                            Text("\(vehicle.state.batteryText) · \(vehicle.state.enduranceText)")
                                .font(.caption)
                                .foregroundStyle(Color.eliteSecondaryText)
                        }
                        Spacer()
                        Image(systemName: model.dashboard.selectedSN == vehicle.vehicle.sn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.dashboard.selectedSN == vehicle.vehicle.sn ? Color.elitePrimaryLight : Color.eliteSecondaryText)
                    }
                    .padding(14)
                    .eliteCard(cornerRadius: 20)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.eliteBackground.ignoresSafeArea())
    }
}

private struct EliteChargeView: View {
    @ObservedObject var model: NinebotViewModel
    var onOpenHome: () -> Void

    private var snapshot: NinebotVehicleSnapshot? {
        model.dashboard.primaryVehicle
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("充电中心")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.elitePrimaryText)
                        Text(snapshot?.vehicle.name ?? "等待连接车辆")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.eliteSecondaryText)
                    }
                    Spacer()
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color.elitePrimaryLight)
                        .frame(width: 46, height: 46)
                        .background(Color.eliteSurfaceHigh, in: Circle())
                }

                if let snapshot {
                    EliteChargingHero(snapshot: snapshot)
                    EliteChargeFacts(snapshot: snapshot)
                    EliteChargingHistoryCard(snapshot: snapshot)
                } else {
                    EliteEmptyVehicleCard(isRefreshing: model.isLoading) {
                        Task { await model.refreshDashboard() }
                    }
                }

                Button(action: onOpenHome) {
                    Label("返回车辆控制", systemImage: "house.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.eliteSurfaceHigh, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.elitePrimaryText)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color.eliteBackground)
    }
}

private struct EliteChargingHero: View {
    var snapshot: NinebotVehicleSnapshot

    private var state: NinebotVehicleState { snapshot.state }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.eliteSurfaceBright, Color.eliteSurface, Color.eliteSurfaceLowest],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Image(eliteTeslaImageName(for: state, isDay: eliteIsDay(at: timeline.date)))
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            LinearGradient(
                                colors: [.clear, Color.eliteSurfaceLowest.opacity(0.52)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .clipped()
                }

                EliteGridGlow()
                    .opacity(0.14)
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

            VStack(spacing: 2) {
                Text(state.isCharging == true ? "正在充电" : "电量概览")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.eliteSecondaryText)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(state.battery.map { String($0) } ?? "--")
                        .font(.system(size: 66, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.elitePrimaryLight)
                    Text("%")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.elitePrimaryText)
                }
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.elitePrimaryLight)
                    Text(state.isCharging == true ? state.chargingPowerText : "未连接充电器")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.elitePrimaryText)
                }
            }

            VStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: [Color.elitePrimaryDark, Color.elitePrimary], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(proxy.size.width * state.batteryFraction, 6))
                    }
                }
                .frame(height: 12)

                HStack {
                    Text("当前电量")
                    Spacer()
                    Text(state.isCharging == true ? "预计充满 \(state.estimatedFullChargeTimeText)" : "预计续航 \(state.enduranceText)")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.eliteSecondaryText)
            }
        }
        .padding(14)
        .eliteCard(cornerRadius: 32, glow: state.isCharging == true)
    }
}

private struct EliteChargeFacts: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        HStack(spacing: 12) {
            EliteCompactMetric(title: "充电功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
            EliteCompactMetric(title: "电池温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
        }
        HStack(spacing: 12) {
            EliteCompactMetric(title: "电池电压", value: snapshot.state.batteryVoltageText, systemImage: "battery.100percent")
            EliteCompactMetric(title: "循环次数", value: snapshot.state.batteryCycleCountText, systemImage: "arrow.trianglehead.2.clockwise")
        }
    }
}

private struct EliteCompactMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.elitePrimaryLight)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.eliteSecondaryText)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.elitePrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(16)
        .eliteCard(cornerRadius: 24)
    }
}

private struct EliteChargingHistoryCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("电池健康")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.elitePrimaryText)
                Spacer()
                Text(snapshot.state.primaryStatusText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.elitePrimaryLight)
            }
            HStack(spacing: 12) {
                EliteHealthRow(title: "预测续航", value: snapshot.state.aiEstimatedMileageText, systemImage: "road.lanes")
                EliteHealthRow(title: "总里程", value: snapshot.state.totalMileageText, systemImage: "gauge.with.dots.needle.67percent")
            }
        }
        .padding(18)
        .eliteCard(cornerRadius: 26)
    }
}

private struct EliteHealthRow: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.elitePrimaryLight)
                .frame(width: 28, height: 28)
                .background(Color.elitePrimary.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.eliteSecondaryText)
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.elitePrimaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EliteChargeDetailView: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        EliteChargingHero(snapshot: snapshot)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.eliteBackground.ignoresSafeArea())
            .navigationTitle("电池详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.eliteBackground, for: .navigationBar)
    }
}

private struct EliteStatusChip: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.elitePrimaryLight)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.elitePrimary.opacity(0.16), in: Capsule())
            .overlay {
                Capsule().stroke(Color.elitePrimary.opacity(0.28), lineWidth: 1)
            }
    }
}

private extension View {
    func eliteCard(cornerRadius: CGFloat, glow: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(
            LinearGradient(
                colors: [Color.eliteSurface.opacity(0.98), Color.eliteSurfaceLowest.opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: shape
        )
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .shadow(color: glow ? Color.elitePrimary.opacity(0.18) : Color.black.opacity(0.26), radius: glow ? 28 : 16, x: 0, y: 10)
    }
}

extension Color {
    static let eliteBackground = Color(uiColor: .systemGroupedBackground)
    static let eliteSurfaceLowest = Color(uiColor: .secondarySystemGroupedBackground)
    static let eliteSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let eliteSurfaceHigh = Color(uiColor: .tertiarySystemGroupedBackground)
    static let eliteSurfaceBright = Color(uiColor: .quaternarySystemFill)
    static let elitePrimary = Color(uiColor: .systemBlue)
    static let elitePrimaryDark = Color(uiColor: .systemIndigo)
    static let elitePrimaryLight = Color(uiColor: .systemBlue)
    static let elitePrimaryText = Color(uiColor: .label)
    static let eliteSecondaryText = Color(uiColor: .secondaryLabel)
    static let eliteOutline = Color(uiColor: .separator).opacity(0.55)
    static let eliteTrack = Color(uiColor: .systemFill)
    static let eliteSuccess = Color(uiColor: .systemGreen)
    static let eliteWarning = Color(uiColor: .systemOrange)
    static let eliteError = Color(uiColor: .systemRed)
}

private func eliteTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
