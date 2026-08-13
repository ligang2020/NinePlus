# mini-ninebot

NineBot+ iOS app, version **7.0.0** (build **7**).

The app's first screen is the **NinePlus account login**. The service URL can be
entered in the app, and an installation-wide Bearer Token can be supplied when
the backend enables API protection. The app stores only the returned per-user
NinePlus session token.

The app talks to the companion NinePlus service, which uses the community
`ninecli` cloud compatibility client. It is not an official public Ninebot
developer API. The official Ninebot cloud binding is configured once on the
server and reused by every device; the iOS app never asks each device for that
password. Cached vehicle data may be kept locally for a smoother dashboard.

## 配置服务器地址并连接 App

当前 v7 App 支持在登录页和「我的 → 服务器连接」中修改后端地址。地址只需要填写协议、主机和端口，不要附加 `/healthz` 或其他接口路径：

- 局域网后端：`http://服务器局域网IP:8765`，例如 `http://192.168.1.100:8765`
- HTTPS 反向代理：`https://你的域名`
- App 与后端不在同一局域网时，不能填写 `127.0.0.1` 或 `localhost`；应填写手机可以访问的服务器 IP、域名或 VPN 地址。

### 后端设置 Bearer Token

在服务器 `server/.env` 中设置与 App 完全一致的随机值：

```env
NINEPLUS_PORTAL_USERNAME=admin
NINEPLUS_PORTAL_PASSWORD=修改为强密码
NINEPLUS_APP_BEARER_TOKEN=修改为随机长Token
```

然后重建服务：

```bash
cd server
docker compose up -d --build
```

Token 不要提交到 Git，也不要放进 Xcode 配置或源码。它只在 App 的「服务保护 Token」字段中输入，App 会自动为 API 请求发送：

```http
Authorization: Bearer <NINEPLUS_APP_BEARER_TOKEN>
```

### 连接检查步骤

1. 先在服务器执行 `curl http://127.0.0.1:8765/healthz`，确认服务已启动。
2. 在同一 Wi-Fi 下，从手机或电脑访问 `http://服务器局域网IP:8765/healthz`；若访问不了，检查飞牛/Docker 端口 `8765` 和防火墙。
3. 打开 App，在登录页填写「服务器地址」和「服务保护 Token」。
4. 点击「测试连接」。看到“服务器连接正常”后，再填写 NinePlus 账号和密码，点击「登录并进入控制台」。
5. 登录后，可在「我的 → 服务器连接」再次修改地址、测试连接或保存并连接。Bearer Token 只显示“已配置”，不会显示完整内容。

`/healthz` 是公开健康检查接口，会返回 `bearer_token_required: true/false`；真正的登录、车辆数据、控制和 APNs 设备登记请求会受到 Bearer Token 保护。若地址正确但测试失败，优先检查手机是否能访问该地址、端口映射是否为 `8765:8765`，以及 HTTPS 证书是否有效。
