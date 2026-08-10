import SwiftUI
import UIKit
import MapKit

struct NinebotSettingsView: View {
    @ObservedObject var model: NinebotViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.hasConnectionSession {
                settingsContent
            } else {
                NinebotCloudLoginView(model: model)
            }
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsProfileCard(
                    snapshot: model.dashboard.primaryVehicle,
                    accountText: model.currentAccountDisplay,
                    dataSourceMode: model.dataSourceMode,
                    vehicleCount: model.dashboard.vehicles.count
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .ninePlusCard(cornerRadius: 28)

                if model.errorMessage != nil || model.statusMessage != nil {
                    SettingsStatusBanner(
                        errorMessage: model.errorMessage,
                        statusMessage: model.statusMessage
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .ninePlusCard(cornerRadius: 24)
                }

                NinebotBuiltInConnectionRow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .ninePlusCard(cornerRadius: 24)

                VehicleEventsCard(events: model.vehicleEvents)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .ninePlusCard(cornerRadius: 24)

                NavigationLink {
                    NinebotDiagnosticsView(model: model)
                } label: {
                    SettingsNavigationRow(
                        title: "诊断中心",
                        subtitle: "刷新、缓存、Widget 和原始字段",
                        systemImage: "stethoscope"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(16)
                .ninePlusCard(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Siri 与快捷指令")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        SettingsButtonLabel(title: "打开 Siri 设置", systemImage: "mic.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(spacing: 10) {
                        ShortcutCapabilityRow(title: "刷新车况", systemImage: "arrow.clockwise")
                        ShortcutCapabilityRow(title: "查询电量", systemImage: "battery.100")
                        ShortcutCapabilityRow(title: "查询位置", systemImage: "location.fill")
                        ShortcutCapabilityRow(title: "寻车铃", systemImage: "bell.fill")
                        ShortcutCapabilityRow(title: "打开座桶", systemImage: "shippingbox.fill")
                        ShortcutCapabilityRow(title: "上电", systemImage: "power.circle.fill")
                        ShortcutCapabilityRow(title: "熄火", systemImage: "lock.fill")
                    }
                    .padding(12)
                    .background(Color.teslaControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .ninePlusCard(cornerRadius: 24)
            }
            .padding(16)
            .padding(.bottom, 18)
        }
        .disabled(model.isLoading)
        .scrollDismissesKeyboard(.interactively)
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isLoading {
                    ProgressView()
                }
            }
        }
    }


}


private struct VehicleEventsCard: View {
    var events: [NinebotVehicleEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("车辆事件记录")
                        .font(.headline.weight(.semibold))
                    Text(events.isEmpty ? "刷新车况后自动记录报警和充电状态变化" : "按时间倒序展示本机已记录的车辆事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundStyle(Color.teslaGreen)
            }

            if events.isEmpty {
                Label("暂无事件，下一次刷新检测到变化后会自动加入列表", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(events) { event in
                        VehicleEventRow(event: event)
                    }
                }
            }
        }
    }
}

private struct VehicleEventRow: View {
    var event: NinebotVehicleEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.type.systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                    Text(event.vehicleName.isEmpty ? event.vehicleSN : event.vehicleName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.dateFormatter.string(from: event.occurredAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(event.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if event.hasCoordinate, let latitude = event.latitude, let longitude = event.longitude {
                Map(position: .constant(.region(Self.region(latitude: latitude, longitude: longitude)))) {
                    Marker(event.title, systemImage: event.type.systemImage, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                        .tint(tint)
                }
                .frame(height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
            } else {
                Label("接口未返回事件坐标", systemImage: "location.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let durationMinutes = event.durationMinutes {
                    EventValuePill(title: "充电耗时", value: Self.durationText(durationMinutes), systemImage: "timer")
                }
                if let chargingPower = event.chargingPower {
                    EventValuePill(title: "充电功率", value: "\(Int(chargingPower.rounded())) W", systemImage: "bolt.fill")
                }
                if let batteryTemperature = event.batteryTemperature {
                    EventValuePill(title: "电池温度", value: "\(String(format: "%.1f", batteryTemperature)) °C", systemImage: "thermometer.medium")
                }
                if let voltage = event.voltage {
                    EventValuePill(title: "电压", value: "\(String(format: "%.1f", voltage)) V", systemImage: "gauge.with.dots.needle.67percent")
                }
            }
        }
        .padding(12)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.14), lineWidth: 1))
    }

    private var tint: Color {
        switch event.type {
        case .alarm: return .orange
        case .chargeStarted: return .blue
        case .chargeEnded: return Color.teslaGreen
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static func durationText(_ minutes: Double) -> String {
        let total = max(Int(minutes.rounded()), 0)
        let hours = total / 60
        let remaining = total % 60
        if hours > 0 { return "\(hours)小时\(remaining)分" }
        return "\(remaining)分钟"
    }

    private static func region(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }
}

private struct EventValuePill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct NinebotBuiltInConnectionRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("九号云接口已内置")
                    .font(.subheadline.weight(.semibold))
                Text("无需填写服务地址或令牌；只需使用九号账号登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsProfileCard: View {
    var snapshot: NinebotVehicleSnapshot?
    var accountText: String
    var dataSourceMode: NinebotDataSourceMode
    var vehicleCount: Int

    var body: some View {
        HStack(spacing: 14) {
            ProfileAvatar(urlString: avatarURLString, displayName: displayName)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(vehicleCount)")
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(Capsule())
                .accessibilityLabel("车辆 \(vehicleCount) 台")
        }
        .padding(.vertical, 6)
    }

    private var displayName: String {
        firstRawString([
            "owner_user_nickname",
            "ownerUserNickname",
            "auth_nickname",
            "authNickname",
            "nickname",
            "user_name",
            "userName"
        ]) ?? cleanAccountText
    }

    private var subtitle: String {
        let vehicleName = snapshot?.vehicle.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !vehicleName.isEmpty {
            return "\(dataSourceMode.shortTitle) · \(vehicleName)"
        }
        return dataSourceMode.title
    }

    private var avatarURLString: String? {
        firstRawString([
            "owner_user_avatar",
            "ownerUserAvatar",
            "auth_avatar",
            "authAvatar",
            "avatar",
            "avatar_url",
            "avatarUrl"
        ])
    }

    private var cleanAccountText: String {
        let value = accountText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "NineBot+" : value
    }

    private func firstRawString(_ keys: [String]) -> String? {
        guard let raw = snapshot?.vehicle.raw else { return nil }
        for key in keys {
            if let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private struct ProfileAvatar: View {
    var urlString: String?
    var displayName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemGroupedBackground))

            if let urlString,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
        }
    }

    private var fallback: some View {
        Text(initialText)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var initialText: String {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first else { return "N" }
        return String(first)
    }
}

private struct SettingsOverviewCard: View {
    var hasConfiguration: Bool
    var dataSourceMode: NinebotDataSourceMode
    var vehicleCount: Int
    var baseURLString: String
    var accountCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                    Image(systemName: hasConfiguration ? dataSourceMode.systemImage : "link.badge.plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(dataSourceMode.title)
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                SettingsInfoPill(title: "车辆", value: "\(vehicleCount)", systemImage: "bolt.car.fill")
                SettingsInfoPill(title: dataSourceMode == .platform ? "归档" : "账号", value: dataSourceMode == .platform ? "开启" : "\(accountCount)", systemImage: dataSourceMode == .platform ? "externaldrive.fill" : "person.fill")
                SettingsInfoPill(title: "快捷指令", value: "7 个", systemImage: "sparkles")
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        return hasConfiguration ? .green : .orange
    }

    private var summaryText: String {
        hasConfiguration ? cleanBaseURL : (dataSourceMode == .platform ? "填写 NinePlus Platform 地址后读取服务器数据" : "填写 ninecli serve 地址后直接读取代理")
    }

    private var cleanBaseURL: String {
        let value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "\(dataSourceMode.shortTitle)地址为空" : value
    }
}

private struct ProxySummaryRow: View {
    var hasConfiguration: Bool
    var dataSourceMode: NinebotDataSourceMode
    var baseURLString: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hasConfiguration ? dataSourceMode.systemImage : "link.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(hasConfiguration ? Color.green : Color.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(hasConfiguration ? "\(dataSourceMode.shortTitle)已配置" : "未配置\(dataSourceMode.shortTitle)")
                    .font(.subheadline.weight(.semibold))
                Text(cleanBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(hasConfiguration ? "可用" : "待连接")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasConfiguration ? .green : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((hasConfiguration ? Color.green : Color.orange).opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private var cleanBaseURL: String {
        let value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未填写\(dataSourceMode.shortTitle)地址" : value
    }
}

private struct SettingsInputField: View {
    var title: String
    var placeholder: String
    var systemImage: String
    @Binding var text: String
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            .keyboardType(keyboardType)
                    }
                }
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
            }
        }
    }
}

private struct PushDeviceTokenRow: View {
    var token: String?
    var hasConfiguration: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: token == nil ? "bell.slash.fill" : "bell.badge.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(token == nil ? Color.orange : Color.green)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(token == nil ? "APNs 设备未上报" : "APNs 设备已就绪")
                    .font(.subheadline.weight(.semibold))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
    }

    private var detailText: String {
        guard let token, !token.isEmpty else {
            return hasConfiguration ? "点“检查权限并上报”，会重新注册 APNs 并同步到服务器后台。" : "先保存 NinePlus 服务器地址和 Token。"
        }
        let prefix = token.prefix(8)
        let suffix = token.suffix(6)
        return "Token \(prefix)...\(suffix)"
    }
}

private struct SettingsNavigationRow: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct NinebotDiagnosticsView: View {
    @ObservedObject var model: NinebotViewModel
    @State private var copiedMessage: String?

    private var diagnostics: NinebotDiagnosticsSnapshot {
        model.diagnosticsSnapshot()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DiagnosticsHeroCard(diagnostics: diagnostics)

                DiagnosticsEventCard(title: "App / 快捷指令", event: diagnostics.lastAppRefreshEvent)
                DiagnosticsEventCard(title: "桌面小组件", event: diagnostics.lastWidgetRefreshEvent)

                DiagnosticsCacheCard(diagnostics: diagnostics)

                Button(role: .destructive) {
                    model.clearMessages()
                    copiedMessage = "已清除当前提示"
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_300_000_000)
                        copiedMessage = nil
                    }
                } label: {
                    SettingsNavigationRow(
                        title: "清除当前提示",
                        subtitle: "移除页面上的状态或错误提示",
                        systemImage: "xmark.circle",
                        tint: .red
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(16)
                .ninePlusCard(cornerRadius: 24)

                DiagnosticsRawCopyCard(
                    snapshot: model.dashboard.primaryVehicle,
                    copiedMessage: $copiedMessage
                )
            }
            .padding(16)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("诊断中心")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let copiedMessage {
                Text(copiedMessage)
                    .font(.footnote.weight(.semibold))
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
}

private struct DiagnosticsHeroCard: View {
    var diagnostics: NinebotDiagnosticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill((diagnostics.hasConfiguration ? Color.green : Color.orange).opacity(0.14))
                    Image(systemName: diagnostics.hasConfiguration ? "checkmark.seal.fill" : "link.badge.plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(diagnostics.hasConfiguration ? Color.green : Color.orange)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostics.selectedVehicleName)
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                    Text(diagnostics.proxyText)
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(diagnostics.vehicleCount)")
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("车辆")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
            }

            HStack(spacing: 10) {
                DiagnosticMetricPill(title: "账号", value: diagnostics.accountText == "未绑定账号" ? "0" : "1", systemImage: "person.fill")
                DiagnosticMetricPill(title: "地址", value: "\(diagnostics.resolvedAddressCount)", systemImage: "map.fill")
                DiagnosticMetricPill(title: "详情", value: "\(diagnostics.rideDetailCount)", systemImage: "doc.text.magnifyingglass")
            }

            if let updatedAt = diagnostics.dashboardUpdatedAt {
                Label("车况更新 \(formatDiagnosticsDate(updatedAt))", systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            if let lastError = diagnostics.lastError, !lastError.isEmpty {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
}

private struct DiagnosticsEventCard: View {
    var title: String
    var event: NinebotRefreshEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.teslaPrimaryText)
                Spacer()
                Text(event?.success == true ? "成功" : "待检查")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(event?.success == true ? Color.green : Color.orange)
            }

            if let event {
                HStack(spacing: 10) {
                    DiagnosticMetricPill(title: "来源", value: event.source, systemImage: "bolt.horizontal")
                    DiagnosticMetricPill(title: "耗时", value: formatDiagnosticsDuration(event.durationSeconds), systemImage: "timer")
                    DiagnosticMetricPill(title: "时间", value: formatDiagnosticsTime(event.endedAt), systemImage: "clock")
                }

                if let message = event.message, !message.isEmpty {
                    Text("\(event.operation) · \(message)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("还没有记录到刷新事件")
                    .font(.subheadline)
                    .foregroundStyle(Color.teslaSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
}

private struct DiagnosticsCacheCard: View {
    var diagnostics: NinebotDiagnosticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地缓存")
                .font(.headline)
                .foregroundStyle(Color.teslaPrimaryText)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                DiagnosticMetricPill(title: "接口行程", value: "\(diagnostics.interfaceRideCount)", systemImage: "road.lanes")
                DiagnosticMetricPill(title: "历史快照", value: "\(diagnostics.historyPointCount)", systemImage: "clock.arrow.circlepath")
                DiagnosticMetricPill(title: "本地轨迹", value: "\(diagnostics.recordedRideCount)", systemImage: "point.3.connected.trianglepath.dotted")
                DiagnosticMetricPill(title: "车况缓存", value: formatDiagnosticsBytes(diagnostics.dashboardCacheBytes), systemImage: "externaldrive.fill")
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
}

private struct DiagnosticsRawCopyCard: View {
    var snapshot: NinebotVehicleSnapshot?
    @Binding var copiedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("原始字段")
                    .font(.headline)
                    .foregroundStyle(Color.teslaPrimaryText)
                Spacer()
                Text(snapshot == nil ? "无车辆" : "可复制")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot == nil ? Color.orange : Color.green)
            }

            Text("复制当前车辆、状态、电池和行程返回值，方便排查字段。")
                .font(.caption)
                .foregroundStyle(Color.teslaSecondaryText)

            Button {
                copyRawPayload()
            } label: {
                Label("复制全部原始字段", systemImage: "doc.on.doc.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.green)
            .disabled(snapshot == nil)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }

    private func copyRawPayload() {
        guard let snapshot else { return }
        let payload: [String: JSONValue] = [
            "vehicle": .object(snapshot.vehicle.raw ?? [:]),
            "status": .object(snapshot.state.rawStatus ?? [:]),
            "battery": .object(snapshot.state.rawBattery ?? [:]),
            "travel": .object(snapshot.state.rawTravel ?? [:])
        ]
        let text = diagnosticsJSONString(.object(payload))
        UIPasteboard.general.string = text
        copiedMessage = "已复制原始字段"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            copiedMessage = nil
        }
    }
}

private struct DiagnosticMetricPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AccountSummaryRow: View {
    var accountText: String
    var loginResult: NinebotLoginResult?
    var hasAccount: Bool
    var dataSourceMode: NinebotDataSourceMode

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((hasAccount ? Color.green : Color.orange).opacity(0.14))
                Image(systemName: hasAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(hasAccount ? Color.green : Color.orange)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(hasAccount ? "当前九号账号" : "绑定九号账号")
                    .font(.subheadline.weight(.semibold))
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let detailText {
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
    }

    private var summaryText: String {
        if hasAccount {
            return accountText
        }
        return dataSourceMode == .platform ? "绑定后自动刷新车辆数据" : "代理模式下直接登录当前代理"
    }

    private var detailText: String? {
        let areaCode = loginResult?.areaCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = loginResult?.region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let businessUID = loginResult?.businessUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [areaCode.isEmpty ? nil : "+\(areaCode)", region.isEmpty ? nil : region, businessUID.isEmpty ? nil : "UID \(businessUID)"]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct SettingsInfoPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SettingsButtonLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 18)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct SettingsCompactButtonLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ShortcutCapabilityRow: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text("已支持")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

private struct SettingsStatusBanner: View {
    var errorMessage: String?
    var statusMessage: String?

    var body: some View {
        if let errorMessage {
            SettingsStatusRow(
                message: errorMessage,
                systemImage: "exclamationmark.triangle.fill",
                color: .red
            )
        } else if let statusMessage {
            SettingsStatusRow(
                message: statusMessage,
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
    }
}

private struct SettingsStatusRow: View {
    var message: String
    var systemImage: String
    var color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private func formatDiagnosticsDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}

private func formatDiagnosticsTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func formatDiagnosticsDuration(_ seconds: Double) -> String {
    if seconds >= 10 {
        return "\(Int(seconds.rounded()))s"
    }
    return String(format: "%.1fs", seconds)
}

private func formatDiagnosticsBytes(_ bytes: Int) -> String {
    guard bytes > 0 else { return "0 B" }
    if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
    if bytes >= 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }
    return "\(bytes) B"
}

private func diagnosticsJSONString(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}

struct NinebotSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            NinebotSettingsView(model: NinebotViewModel())
                .navigationTitle("我的")
        }
    }
}
