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

   至少修改 `NINEPLUS_PORTAL_PASSWORD`。不要把 `.env` 提交到 Git。

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
