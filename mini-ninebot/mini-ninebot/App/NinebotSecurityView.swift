import CoreLocation
import MapKit
import SwiftUI

/// A focused safety surface for the fifth root tab. It deliberately reuses the
/// same live snapshot as the control screen, so lock/power/location never drift
/// into a second source of truth.
struct NinebotSecurityView: View {
    @ObservedObject var model: NinebotViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var snapshot: NinebotVehicleSnapshot? {
        model.dashboard.primaryVehicle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SecurityHeroCard(snapshot: snapshot)

                if let snapshot {
                    SecurityStatusCard(snapshot: snapshot) {
                        Task { await model.refreshDashboard() }
                    }

                    if let coordinate = securityCoordinate(for: snapshot.state) {
                        SecurityLocationCard(
                            snapshot: snapshot,
                            address: model.resolvedAddressText(for: snapshot),
                            coordinate: coordinate,
                            cameraPosition: $cameraPosition
                        )
                    } else {
                        SecurityEmptyLocationCard()
                    }
                } else {
                    SecurityEmptyLocationCard(message: "登录并刷新车况后，这里会显示车辆的实时位置。")
                }

                SecurityGuidanceCard()
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isLoading { ProgressView() }
            }
        }
    }
}

private struct SecurityHeroCard: View {
    var snapshot: NinebotVehicleSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("车辆安全")
                        .font(.largeTitle.weight(.bold))
                    Text(snapshot?.vehicle.name ?? "等待连接车辆")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.teslaGreen)
                    .frame(width: 48, height: 48)
                    .background(Color.teslaGreen.opacity(0.13), in: Circle())
            }

            Text("集中查看防盗状态、车辆位置和最近一次云端更新时间。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .ninePlusCard(cornerRadius: 26)
    }
}

private struct SecurityStatusCard: View {
    var snapshot: NinebotVehicleSnapshot
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("防盗状态", systemImage: "lock.shield.fill")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(statusTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(statusColor.opacity(0.13), in: Capsule())
            }

            HStack(spacing: 10) {
                SecurityMetric(title: "锁车", value: snapshot.state.lockText, systemImage: snapshot.state.isLocked == true ? "lock.fill" : "lock.open.fill", tint: statusColor)
                SecurityMetric(title: "电源", value: snapshot.state.powerText, systemImage: "power", tint: snapshot.state.isPoweredOn == true ? .orange : .secondary)
                SecurityMetric(title: "更新", value: securityTime(snapshot.state.updatedAt), systemImage: "clock.fill", tint: .secondary)
            }

            Button(action: onRefresh) {
                Label("刷新安全状态", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.teslaGreen)
        }
        .padding(16)
        .ninePlusCard(cornerRadius: 24)
    }

    private var statusTitle: String {
        if snapshot.state.isLocked == true { return "已保护" }
        if snapshot.state.isPoweredOn == true { return "请注意" }
        return "状态未知"
    }

    private var statusColor: Color {
        if snapshot.state.isLocked == true { return Color.teslaGreen }
        if snapshot.state.isPoweredOn == true { return .orange }
        return .secondary
    }
}

private struct SecurityMetric: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.teslaControlBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct SecurityLocationCard: View {
    var snapshot: NinebotVehicleSnapshot
    var address: String?
    var coordinate: CLLocationCoordinate2D
    @Binding var cameraPosition: MapCameraPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("车辆当前位置")
                        .font(.headline.weight(.semibold))
                    Text(addressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "location.fill")
                    .foregroundStyle(Color.teslaGreen)
            }

            Map(position: $cameraPosition) {
                Marker(snapshot.vehicle.name, systemImage: "scooter", coordinate: coordinate)
                    .tint(Color.teslaGreen)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 8) {
                SecurityCoordinatePill(title: "纬度", value: securityCoordinateText(coordinate.latitude))
                SecurityCoordinatePill(title: "经度", value: securityCoordinateText(coordinate.longitude))
            }

            Button {
                let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
                item.name = snapshot.vehicle.name
                item.openInMaps()
            } label: {
                Label("在 Apple 地图中查看", systemImage: "map.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Color.teslaGreen)
        }
        .padding(16)
        .ninePlusCard(cornerRadius: 24)
        .onAppear {
            cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
        }
    }

    private var addressText: String {
        let value = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "实时坐标已返回" : value
    }
}

private struct SecurityCoordinatePill: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.teslaControlBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct SecurityEmptyLocationCard: View {
    var message: String = "接口暂未返回车辆坐标，刷新后会自动补齐定位信息。"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("车辆位置", systemImage: "location.slash")
                .font(.headline.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .ninePlusCard(cornerRadius: 24)
    }
}

private struct SecurityGuidanceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("安全提示", systemImage: "lightbulb.fill")
                .font(.headline.weight(.semibold))
            Text("离开车辆前请确认已熄火并锁车。云端定位可能受网络、卫星信号和车辆休眠策略影响，请以最新更新时间为准。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private func securityCoordinate(for state: NinebotVehicleState) -> CLLocationCoordinate2D? {
    guard let latitude = state.latitude, let longitude = state.longitude,
          (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
    return NinebotCoordinateTransform.mapKitCoordinate(latitude: latitude, longitude: longitude)
}

private func securityCoordinateText(_ value: Double) -> String {
    String(format: "%.5f", value)
}

private func securityTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
