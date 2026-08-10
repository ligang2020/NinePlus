//
//  ContentView.swift
//  mini-ninebot
//

import SwiftUI
import UIKit

private enum NinebotRootTab: Hashable {
    case dashboard
    case trips
    case recording
    case settings
}

struct ContentView: View {
    @StateObject private var model = NinebotViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: NinebotRootTab = .dashboard

    var body: some View {
        Group {
            if model.hasConnectionSession {
                authenticatedContent
            } else {
                NinebotCloudLoginView(model: model)
            }
        }
        .tint(Color(red: 0.13, green: 0.82, blue: 0.28))
        .task {
            await model.refreshOnLaunchIfPossible()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await model.refreshWhenActiveIfPossible() }
        }
    }

    private var authenticatedContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NinebotDashboardView(model: model) {
                    selectedTab = .trips
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("车控", systemImage: "dot.circle.and.cursorarrow")
            }
            .tag(NinebotRootTab.dashboard)

            NavigationStack {
                NinebotTripsTabView(model: model)
            }
            .tabItem {
                Label("行程", systemImage: "road.lanes")
            }
            .tag(NinebotRootTab.trips)

            NavigationStack {
                NinebotRecordingView(model: model)
            }
            .tabItem {
                Label("记录", systemImage: "gauge.with.dots.needle.67percent")
            }
            .tag(NinebotRootTab.recording)

            NavigationStack {
                NinebotSettingsView(model: model)
                    .navigationTitle("我的")
                    .toolbar(.visible, for: .navigationBar)
            }
            .tabItem {
                Label("我的", systemImage: "person.crop.circle")
            }
            .tag(NinebotRootTab.settings)
        }
    }
}

private enum NinebotCloudLoginField: Hashable {
    case account
    case password
}

struct NinebotCloudLoginView: View {
    @ObservedObject var model: NinebotViewModel
    @FocusState private var focusedField: NinebotCloudLoginField?

    private var canLogin: Bool {
        !model.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.password.isEmpty && !model.isLoading
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.98, blue: 0.94),
                    Color(red: 0.98, green: 0.99, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "car.side.and.exclamationmark.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color(red: 0.13, green: 0.72, blue: 0.24))
                        .frame(width: 78, height: 78)
                        .background(.white.opacity(0.86))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("登录九号账号")
                            .font(.largeTitle.weight(.bold))
                        Text("使用九号官方账号登录，直接获取你的车辆、车况和电量信息。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 14) {
                        CloudLoginField(
                            title: "手机号 / 邮箱",
                            placeholder: "请输入九号账号",
                            systemImage: "person.fill",
                            text: $model.account,
                            focusedField: $focusedField,
                            field: .account,
                            keyboardType: .emailAddress,
                            textContentType: .username
                        )
                        CloudLoginField(
                            title: "密码",
                            placeholder: "请输入九号账号密码",
                            systemImage: "lock.fill",
                            text: $model.password,
                            focusedField: $focusedField,
                            field: .password,
                            isSecure: true,
                            textContentType: .password
                        )
                    }

                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = model.statusMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        focusedField = nil
                        Task { await model.loginWithPassword() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isLoading { ProgressView().tint(.white) }
                            Text(model.isLoading ? "正在登录…" : "登录并获取车辆")
                                .font(.headline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .foregroundStyle(.white)
                        .background(canLogin ? Color(red: 0.13, green: 0.72, blue: 0.24) : Color.gray.opacity(0.35))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canLogin)

                    Text("账号密码仅用于本次九号云登录，登录完成后不会保存密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .background(.white.opacity(0.90))
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 14)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
            }
        }
        .onSubmit {
            guard canLogin else { return }
            Task { await model.loginWithPassword() }
        }
    }
}

private struct CloudLoginField<Field: Hashable>: View {
    let title: String
    let placeholder: String
    let systemImage: String
    @Binding var text: String
    var focusedField: FocusState<Field?>.Binding
    let field: Field
    var keyboardType: UIKeyboardType = .default
    var isSecure = false
    var textContentType: UITextContentType? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .focused(focusedField, equals: field)
                .submitLabel(.next)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color.black.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
