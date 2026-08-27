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

                ServerConnectionCard(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .ninePlusCard(cornerRadius: 24)

                if model.errorMessage != nil || model.statusMessage != nil {
                    SettingsStatusBanner(
                        errorMessage: model.errorMessage,
                        statusMessage: model.statusMessage
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .ninePlusCard(cornerRadius: 24)
                }

                DeviceNotificationsCard(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .ninePlusCard(cornerRadius: 24)

                AlarmRecordsCard(events: model.vehicleEvents)
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


private struct ServerConnectionCard: View {
    @ObservedObject var model: NinebotViewModel

    private var canUseAddress: Bool {
        !model.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
                    .frame(width: 34, height: 34)
                    .background(Color.teslaGreen.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("服务器连接")
                        .font(.headline.weight(.semibold))
                    Text("App 的请求会自动携带 Bearer Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("服务器地址")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    TextField("http://192.168.1.100:8765", text: $model.baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(Color.teslaControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            Text("局域网填写 http://服务器IP:8765；如果使用域名或反向代理，请填写完整的 https://地址。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await model.testConnection() }
                } label: {
                    SettingsCompactButtonLabel(title: "测试连接", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!canUseAddress)

                Button {
                    Task { await model.connectToService() }
                } label: {
                    SettingsCompactButtonLabel(title: "保存并连接", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUseAddress)
            }

            HStack(spacing: 8) {
                Image(systemName: model.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key.slash" : "key.fill")
                    .foregroundStyle(model.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : Color.teslaGreen)
                Text(model.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bearer Token：未填写" : "Bearer Token：已配置（不会显示完整内容）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceNotificationsCard: View {
    @ObservedObject var model: NinebotViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
                    .frame(width: 34, height: 34)
                    .background(Color.teslaGreen.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("设备通知")
                        .font(.headline.weight(.semibold))
                    Text("充电、骑行与车辆报警会登记到本机记录；后端可向已上报的 APNs 设备发送通知。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsInputField(
                title: "服务保护 Token（后端启用 Bearer 时必填）",
                placeholder: "NINEPLUS_APP_BEARER_TOKEN",
                systemImage: "key.fill",
                text: $model.bearerToken,
                isSecure: true,
                textContentType: .password
            )

            PushDeviceTokenRow(token: model.pushDeviceToken, hasConfiguration: model.hasConfiguration)

            HStack(spacing: 10) {
                Button {
                    Task { await model.enableChargingNotifications() }
                } label: {
                    SettingsCompactButtonLabel(
                        title: "开启通知",
                        systemImage: "bell.badge.fill"
                    )
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.syncPushDeviceToken() }
                } label: {
                    SettingsCompactButtonLabel(
                        title: "重新上报",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.bordered)
            }

            Text("若服务器设置了 NINEPLUS_APP_BEARER_TOKEN，请先填入相同值并点“开启通知”。Token 会与 APNs 设备 Token 一起通过 HTTPS 上报，不会显示完整内容。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AlarmRecordsCard: View {
    var events: [NinebotVehicleEvent]

    private var notificationEvents: [NinebotVehicleEvent] {
        events.sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        SettingsRecordCard(
            title: "车辆通知记录",
            subtitle: notificationEvents.isEmpty ? "暂无充电、骑行或报警通知" : "每条均标注车辆、时间与事件位置",
            systemImage: "tray.full.fill",
            tint: .orange,
            badge: notificationEvents.isEmpty ? nil : "\(notificationEvents.count)"
        ) {
            if notificationEvents.isEmpty {
                EmptySettingsRecord(message: "刷新车况后，新的充电、骑行和服务端报警会自动记录。", systemImage: "checkmark.shield")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(notificationEvents) { event in
                        VehicleNotificationRecordRow(event: event)
                    }
                }
            }
        }
    }
}

private struct VehicleNotificationRecordRow: View {
    var event: NinebotVehicleEvent

    private var tint: Color {
        switch event.type {
        case .alarm: return .orange
        case .chargeStarted, .chargeEnded: return Color.teslaGreen
        case .rideStarted, .rideEnded: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.type.systemImage)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.vehicleName.isEmpty ? "未知车辆" : event.vehicleName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                        Text("·").foregroundStyle(.secondary)
                        Text(event.occurredAt.formatted(.dateTime.month().day().hour().minute()))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
            }
            Text(event.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let durationMinutes = event.durationMinutes,
               (event.type == .rideEnded || event.type == .chargeEnded) {
                EventValuePill(title: "持续时间", value: Self.durationText(durationMinutes), systemImage: "timer")
            }
            if let power = event.chargingPower {
                EventValuePill(title: "功率", value: formatNumber(power, unit: " W", maximumFractionDigits: 0), systemImage: "bolt.fill")
            }
            EventLocationMap(event: event, tint: tint)
        }
        .padding(14)
        .background(Color.teslaControlBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static func durationText(_ minutes: Double) -> String {
        let total = max(Int(minutes.rounded()), 0)
        let hours = total / 60
        let remainder = total % 60
        return hours > 0 ? "\(hours)小时\(remainder)分" : "\(remainder)分钟"
    }
}

private struct SettingsRecordCard<Content: View>: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var badge: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(.red, in: Circle())
                        .accessibilityLabel("\(badge) 条")
                }
            }
            content()
        }
    }
}

private struct EmptySettingsRecord: View {
    var message: String
    var systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

private struct AlarmRecordRow: View {
    var event: NinebotVehicleEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordHeader(event: event, tint: .orange)
            Text(event.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EventLocationMap(event: event, tint: .orange)
        }
        .padding(12)
        .background(Color.teslaControlBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ChargingRecordRow: View {
    var endEvent: NinebotVehicleEvent
    var startEvent: NinebotVehicleEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordHeader(event: endEvent, tint: Color.teslaGreen)

            HStack(spacing: 8) {
                ChargingTimePill(title: "开始", value: startEvent.map { Self.dateFormatter.string(from: $0.occurredAt) } ?? "未返回", systemImage: "play.fill")
                ChargingTimePill(title: "结束", value: Self.dateFormatter.string(from: endEvent.occurredAt), systemImage: "checkmark")
            }

            if let detail = startEvent?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let durationMinutes = endEvent.durationMinutes {
                    EventValuePill(title: "总耗时", value: Self.durationText(durationMinutes), systemImage: "timer")
                }
                if let power = endEvent.chargingPower ?? startEvent?.chargingPower {
                    EventValuePill(title: "充电功率", value: "\(Int(power.rounded())) W", systemImage: "bolt.fill")
                }
                if let temperature = endEvent.batteryTemperature ?? startEvent?.batteryTemperature {
                    EventValuePill(title: "电池温度", value: String(format: "%.1f °C", temperature), systemImage: "thermometer.medium")
                }
                if let voltage = endEvent.voltage {
                    EventValuePill(title: "结束电压", value: String(format: "%.1f V", voltage), systemImage: "gauge.with.dots.needle.67percent")
                }
            }

            EventLocationMap(event: endEvent, tint: Color.teslaGreen)
        }
        .padding(12)
        .background(Color.teslaControlBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        return hours > 0 ? "\(hours)小时\(remaining)分" : "\(remaining)分钟"
    }
}

private struct RecordHeader: View {
    var event: NinebotVehicleEvent
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.type.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.subheadline.weight(.semibold))
                Text(event.vehicleName.isEmpty ? event.vehicleSN : event.vehicleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !event.vehicleSN.isEmpty, event.vehicleName != event.vehicleSN {
                    Text("车辆 SN：\(event.vehicleSN)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(Self.dateFormatter.string(from: event.occurredAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct ChargingTimePill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption2.weight(.bold)).foregroundStyle(Color.teslaGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color.teslaPageBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EventLocationMap: View {
    var event: NinebotVehicleEvent
    var tint: Color

    var body: some View {
        if event.hasCoordinate, let latitude = event.latitude, let longitude = event.longitude {
            Map(position: .constant(.region(Self.region(latitude: latitude, longitude: longitude)))) {
                Marker(event.title, systemImage: event.type.systemImage, coordinate: NinebotCoordinateTransform.mapKitCoordinate(latitude: latitude, longitude: longitude))
                    .tint(tint)
            }
            .frame(height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
            .overlay(alignment: .bottomLeading) {
                Label("事件位置", systemImage: "location.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        } else {
            Label("接口未返回事件坐标", systemImage: "location.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static func region(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        let coordinate = NinebotCoordinateTransform.mapKitCoordinate(latitude: latitude, longitude: longitude)
        return MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012))
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
                Text("九号云端由服务器统一管理。若服务器开启 Bearer 保护，请在“设备通知”填写服务保护 Token。")
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
