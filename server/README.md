# NinePlus · 飞牛 NAS 部署

NinePlus 是一个 FastAPI + Docker Web 控制台：首次在服务器完成九号云端绑定后，所有设备只需登录 NinePlus 账号即可查看车辆、电池、位置、骑行记录，并执行已确认的远程控制。九号官方账号凭据保存在服务器持久化目录，不会要求每台手机或浏览器重复输入。

> 上游使用社区 `ninecli` 调用九号用户云服务，不是九号官方公开开发者 API。云端接口或账号策略变化时，控制台会明确显示错误，不会把失败误报为成功。

## 在飞牛 fnOS 上部署（推荐）

1. 将仓库放到飞牛共享文件夹，例如 `/vol1/1000/docker/NinePlus`。
2. 进入 `server` 目录，复制环境模板并修改密码：

   ```bash
   cp .env.example .env
   chmod 600 .env
   vi .env
   ```

   至少修改 `NINEPLUS_PORTAL_PASSWORD`。如需限制 App/API 访问，请同时设置一个随机的 `NINEPLUS_APP_BEARER_TOKEN`；iOS App 在登录前的「服务保护 Token」中填写同一值，APNs 设备 Token 上报也会携带 `Authorization: Bearer <Token>`。不要把 `.env` 提交到 Git。

首次部署仍需要管理员在服务器端完成一次九号云端绑定；绑定成功后，其他设备只登录 NinePlus 即可。
3. 在飞牛「Docker / 项目」中新建项目：
   - 项目目录：`.../NinePlus/server`
   - Compose 文件：`compose.yaml`
   - 构建并启动：开启
4. 或在 SSH 中执行：

   ```bash
   cd /vol1/1000/docker/NinePlus/server
   docker compose up -d --build
   docker compose ps
   curl http://127.0.0.1:8765/healthz
   ```
5. 浏览器打开 `http://飞牛IP:8765`。如使用飞牛反向代理，请将上游指向 `127.0.0.1:8765`，并把 `NINEPLUS_COOKIE_SECURE=true`。

项目使用普通端口映射而不是 host 网络，适配飞牛项目编排和端口管理；九号云端绑定、会话和推送设备数据持久化在 `server/persistent-sessions`。同一 NinePlus 用户从不同设备登录时，会自动复用服务器上的九号云端绑定。

## 常用维护

```bash
docker compose logs -f --tail=200
docker compose restart
docker compose pull  # 仅在改为远程镜像时使用
docker compose up -d --build
docker compose down   # 不会删除 persistent-sessions
```

升级前建议备份 `persistent-sessions`。不要删除该目录，否则九号云绑定会丢失，需要在服务器端重新绑定；删除浏览器 Cookie 或更换设备不会影响绑定。

## 端点与检查

- Web 控制台：`/`
- 健康检查：`/healthz`
- OpenAPI：`/api/docs`
- 车辆数据：`/dashboard`、`/vehicles/{sn}/status`、`/vehicles/{sn}/battery`
- 行程：`/vehicles/{sn}/travel`
- 远程控制：`POST /vehicles/{sn}/control`，必须提交 `confirm: true`

所有 API 成功响应统一为 `{"ok": true, "data": ...}`；错误响应统一为 `{"ok": false, "error": ...}`。九号密码不会写入日志，也不会返回到浏览器响应。


## iOS APNs 与 Bearer Token

App 在「我的 → 设备通知」中会请求系统通知权限、注册 APNs 并将设备 Token 上报到 `POST /devices/register`。若服务器设置了 `NINEPLUS_APP_BEARER_TOKEN`，必须先在 App 登录页或「设备通知」卡填写相同 Token；否则服务器会返回 `bearer_token_required`，设备不会登记。Token 只用于请求鉴权，服务器不会在接口响应或日志中返回 APNs Token。

### 配置真实的 APNs 远程通知

仅完成 App 内的「允许通知」还不够：要让充电、骑行和报警变更真正显示为 iPhone 远程通知，服务器还需要 Apple Developer 的 APNs Provider 凭据。

1. 在 Apple Developer 中为实际发布使用的 App ID 开启 **Push Notifications**，创建 APNs Auth Key，并记录 **Key ID** 和 **Team ID**。
2. 将下载的 `.p8` 私钥放到服务器仅自己可读的持久化目录，例如 `server/persistent-sessions/AuthKey_XXXXXXXXXX.p8`；不要放进仓库、镜像或 GitHub Actions 日志。
3. 在服务器 `.env` 设置：

   ```env
   NINEPLUS_APNS_KEY_ID=XXXXXXXXXX
   NINEPLUS_APNS_TEAM_ID=你的AppleTeamID
   NINEPLUS_APNS_AUTH_KEY_PATH=/run/nineplus/sessions/AuthKey_XXXXXXXXXX.p8
   NINEPLUS_APNS_REQUEST_TIMEOUT=10
   ```

4. 重建并重启服务：`docker compose up -d --build`。服务会在每次 App 请求 `/dashboard` 刷新车况时比较前后状态，并向已登记设备发送「开始/结束充电」「开始/结束骑行」及九号接口返回的 `alarm`/`fault`/`error` 报警；**不会**把“当前未锁车”当作报警。

当前示例工程 Bundle ID 是 `com.example.NineBotPlus`，只适合本地开发示例。正式安装必须替换为你的 Apple Developer Team 旗下的真实 Bundle ID、使用匹配的签名与 Push capability；Development/Sandbox 安装包走 APNs sandbox，Release/Production 安装包走 production。`NINEPLUS_APP_BEARER_TOKEN` 仅保护 App 到 NinePlus 后端的 HTTP 请求，不是 Apple APNs Provider Token。
## 使用 Cloudflare Tunnel 对外提供服务（推荐）

当前后端是依赖 `ninecli`、子进程和持久化会话目录的 FastAPI + Docker 服务，最稳妥的 Cloudflare 方案是：**后端继续运行在飞牛/NAS 或服务器上，由 Cloudflare Tunnel 安全接入**，而不是把这个后端直接改造成无状态 Worker。这样九号云端绑定、登录会话和 APNs 私钥仍然保存在 `persistent-sessions`，同时不需要在路由器开放 8765 端口。

Cloudflare 的 Python Workers 虽然支持 FastAPI，但本项目还需要 Docker 中的完整 Python 运行时、`ninecli` 子进程以及可写持久化目录；直接迁移到 Worker 会丢失这些运行时能力。Cloudflare Containers 可以运行 Docker 镜像，但部署需要 Cloudflare 账号权限，并且仍需额外设计会话/文件持久化。因此本项目默认提供 Tunnel 集成。

### 1. 在 Cloudflare 创建 Tunnel

1. 在 Cloudflare Zero Trust 控制台创建一个 Tunnel，选择 **Cloudflared / Docker** 连接器。
2. 添加一个 Public Hostname，例如 `nineplus.example.com`，服务类型选 `HTTP`，服务地址填写：

   ```text
   http://nineplus:8765
   ```

   这里的 `nineplus` 是本 Compose 网络中的后端服务名，不是公网 IP。
3. 复制 Cloudflare 给出的 Tunnel Token。不要把它提交到 Git。

### 2. 配置并启动

在部署服务器的 `server` 目录执行：

```bash
cp .env.example .env                 # 已有 .env 时不要覆盖
chmod 600 .env
vi .env
```

至少确认以下配置：

```env
NINEPLUS_PORTAL_PASSWORD=换成高强度密码
NINEPLUS_COOKIE_SECURE=true
CLOUDFLARE_TUNNEL_TOKEN=你的TunnelToken
```

然后启动后端和 Tunnel：

```bash
docker compose --profile cloudflare up -d --build
docker compose ps
curl -fsS https://nineplus.example.com/healthz
```

正常时健康检查会返回 `{"ok":true,...}`。查看 Tunnel 日志：

```bash
docker compose logs -f --tail=200 cloudflared
```

Cloudflare Tunnel 是出站连接，不要求把 8765 映射到公网；确认服务器防火墙只允许内网访问 8765，或者按你的 NAS 管理需求移除 `ports` 配置。

### 3. 配置 iOS App

在 App 的 NinePlus 服务器地址中填写完整的 HTTPS 地址，例如：

```text
https://nineplus.example.com
```

不要填写 `:8765`，也不要把 Tunnel Token 填进 App 的 Bearer Token。若 `.env` 设置了 `NINEPLUS_APP_BEARER_TOKEN`，App 中的服务保护 Token 才填写该值。
