# NineBot+

NineBot+ is a personal iOS app for viewing and managing Ninebot vehicle status,
with Home Screen widgets, Lock Screen widgets, Siri Shortcuts, trip history,
location views, and local ride recording.

## iOS login flow

The iOS app no longer displays a service-address or bearer-token form. The
release build contains the service URL; the only credential entered in the app
is the user's Ninebot account and password. After login, the app fetches
vehicle, status, battery, location, and trip data and stores only the returned
per-login session token.
The password is cleared from memory after login and is not persisted.

The cloud compatibility layer is the repository's `server/` service, which
invokes the MIT-licensed community `ninecli` client. This is not an official
public Ninebot developer API; Ninebot may change the user-facing cloud service
without notice. The app therefore keeps the cloud protocol behind this stable
server boundary instead of embedding an unsupported executable into iOS.

## Build and IPA

Version 8 updates the vehicle stage so parked, driving, and charging states
switch between the supplied daytime and nighttime artwork by local time. The
daytime window is 06:00–18:59, and the existing static route map and vehicle
controls remain available.

Version **37**, build **37** is configured in the Xcode project. In the
driving state, the home screen removes the cycling glyph from the vehicle-stage
badge, shows a car icon with “车辆行驶中”, and replaces current speed with the
live cumulative distance. App launch and each foreground restoration refresh
the vehicle dashboard while background refreshes reuse the short server cache.

首页里程卡片显示今日里程；充电详情在后台补抓电池诊断数据，并提供充电功率曲线卡片。

Web 版本 **v32** 在充电记录页加入通栏“充电功率曲线”卡片：使用 Tailwind 深色毛玻璃卡片与纯 SVG 平滑面积图，支持实时功率、峰值/平均功率、时间轴、悬浮/键盘数据点，以及移动端响应式布局。构建 Web 版本：`cd web && npm run build`。

GitHub Actions builds an unsigned device IPA and uploads it to workflow
artifacts. Pushing tag `v37` also creates or updates the matching GitHub Release
with the IPA and its SHA-256 checksum. Artifact upload needs no release secret.
If the repository blocks GitHub's automatic workflow token from creating
releases, add a fine-grained `GH_RELEASE_TOKEN` Actions secret with repository
**Contents: Read and write** permission; otherwise the workflow still succeeds
and leaves the IPA in Actions artifacts.

For a local package, use Xcode 16.4 or newer:

```bash
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer \
  scripts/package-unsigned-ipa.sh --output build/ipa-v37 --derived-data build/DerivedData-v37
```

## v37 行程日期校正

- 修复历史月行程列表把月度归档 `date` / `day`（常为该月最后一天）误当作每一条行程开始时间的问题。
- 优先解析真实的开始/结束时间字段，并支持常见的嵌套行程详情字段。
- 仅在同月记录拥有多个不同的明确日期时才使用日期型回退；同一个月末日期重复出现时不再伪造为真实行程日期。
- 升级后自动失效旧的行程归档和月度同步标记，重新同步历史月份以清除 v36 留下的错误日期缓存。

## v36 历史月份行程解析修复

- 修复 `/travel-sync` 返回 `records` / `items` 时，iOS 只读取 `list` 而把真实历史行程解析成空列表的问题。
- 同时兼容 `records`、`items`、`list`、`rows`、`travels` 及根数组等 Ninebot 行程响应格式。
- 升级后自动废弃 v35 误写的空月份同步标记，首次打开 2026.07 等历史月份会立即重新从真实接口获取数据。

## v35 行程记录同步

- 首页底部入口统一命名为“行程记录”。
- 打开或切换月份时，App 会按需同步该月的真实 Ninebot 归档数据；成功的空月份也会被记录，避免重复请求。
- 历史月同步成功后直接合并并展示本地行程归档，不再等待一次可能省略历史行程的 Dashboard 刷新。
- 获取失败时显示明确错误和“重新获取”，不会误显示为“暂无行程”。

## v34 首页刷新与原生充电功率分析

- 原生充电页的功率曲线使用真实历史采样，不再生成预览假数据。
- 新增 `ChargingPowerPoint`、`ChargingSegment`、`ChargingSession` 与独立阶段分析器，支持启动、高功率、稳定、降功率和结束阶段。
- 采用中位数滤波和至少连续 3 个采样点的高功率判定，单点尖峰会标记为“瞬时峰值”，不会误判为高功率阶段。
- 每次车况同步在充电期间按 10 秒间隔缓存功率、电压、温度和 SOC；充电结束时保存本次充电会话。
- 首页支持下拉刷新，同步数据沿用现有 Ninebot 服务和缓存链路。
- 首页自动刷新调整为充电中 10 秒、非充电 30 秒；手动刷新增加 4 秒防抖，并与自动刷新互斥，避免重复请求。
- 自动刷新统一携带 `fresh=1`，避免请求成功后仍展示后端短缓存；后端异常时保留最近有效快照并提示缓存时间。

## Backend

```bash
docker compose -f server/compose.yaml up -d --build
```

See [`server/README.md`](server/README.md) for deployment and
[`docs/ninebot-interface-analysis.md`](docs/ninebot-interface-analysis.md) for
the upstream interface boundary.

## Widgets and privacy

Widgets read the latest cached vehicle snapshot from the shared App Group
container. Do not commit account passwords, cloud tokens, signing material,
provisioning profiles, or generated build artifacts.
