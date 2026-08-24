//
//  ContentView.swift
//  mini-ninebot
//

import SwiftUI
import UIKit


struct ContentView: View {
    @StateObject private var model = NinebotViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.hasConnectionSession {
                authenticatedContent
            } else {
                NinebotCloudLoginView(model: model)
            }
        }
        .tint(Color(red: 0.153, green: 0.369, blue: 0.996))
        .task {
            await model.refreshOnLaunchIfPossible()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                model.stopForegroundRefreshLoop()
                return
            }
            Task { await model.refreshWhenActiveIfPossible() }
        }
    }

    private var authenticatedContent: some View {
        EliteMobilityShell(model: model)
    }

}

private enum NinebotCloudLoginField: Hashable {
    case serverAddress
    case account
    case password
    case bearerToken
}

struct NinebotCloudLoginView: View {
    @ObservedObject var model: NinebotViewModel
    @FocusState private var focusedField: NinebotCloudLoginField?

    private var canLogin: Bool {
        model.hasConfiguration
            && !model.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.portalPassword.isEmpty
            && !model.isLoading
    }

    private var canTestConnection: Bool {
        model.hasConfiguration && !model.isLoading
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.eliteBackground, Color.eliteSurfaceLowest],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "scooter")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color.elitePrimaryLight)
                        .frame(width: 78, height: 78)
                        .background(Color.eliteSurfaceHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("登录 NinePlus")
                            .font(.largeTitle.weight(.bold))
                        Text("登录 NinePlus 账号即可进入。九号官方账号由服务器统一管理，不需要在每台设备重复登录。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 14) {
                        CloudLoginField(
                            title: "服务器地址",
                            placeholder: "http://192.168.1.100:8765",
                            systemImage: "server.rack",
                            text: $model.baseURLString,
                            focusedField: $focusedField,
                            field: .serverAddress,
                            keyboardType: .URL,
                            textContentType: .URL
                        )
                        Text("填写运行 NinePlus 后端的地址。局域网示例：http://192.168.1.100:8765；使用域名时请填写 https://域名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        CloudLoginField(
                            title: "手机号 / 邮箱",
                            placeholder: "请输入 NinePlus 账号",
                            systemImage: "person.fill",
                            text: $model.portalUsername,
                            focusedField: $focusedField,
                            field: .account,
                            keyboardType: .emailAddress,
                            textContentType: .username
                        )
                        CloudLoginField(
                            title: "密码",
                            placeholder: "请输入 NinePlus 密码",
                            systemImage: "lock.fill",
                            text: $model.portalPassword,
                            focusedField: $focusedField,
                            field: .password,
                            isSecure: true,
                            textContentType: .password
                        )
                        CloudLoginField(
                            title: "服务保护 Token（可选）",
                            placeholder: "后端开启 Bearer 时填写",
                            systemImage: "key.fill",
                            text: $model.bearerToken,
                            focusedField: $focusedField,
                            field: .bearerToken,
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

                    HStack(spacing: 10) {
                        Button {
                            focusedField = nil
                            Task { await model.testConnection() }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "bolt.horizontal.circle")
                                Text("测试连接")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canTestConnection)

                        Button {
                            focusedField = nil
                            Task { await model.loginToNinePlus() }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isLoading { ProgressView().tint(.white) }
                                Text(model.isLoading ? "正在登录…" : "登录并进入控制台")
                                    .font(.headline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .foregroundStyle(.white)
                            .background(canLogin ? Color.elitePrimary : Color.eliteSurfaceBright)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canLogin)
                    }

                    Text("NinePlus 密码仅用于建立当前登录会话；如服务器设置了 NINEPLUS_APP_BEARER_TOKEN，请先填写相同的服务保护 Token。九号云端凭据保存在服务器，不会写入本设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .background(Color.eliteSurface.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1) }
                .shadow(color: Color.elitePrimary.opacity(0.14), radius: 24, x: 0, y: 14)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
            }
        }
        .onSubmit {
            guard canLogin else { return }
            Task { await model.loginToNinePlus() }
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
            .background(Color.eliteSurfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
