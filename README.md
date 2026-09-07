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

Version **43**, build **43** is configured in the Xcode project. In the
driving state, the home screen removes the cycling glyph from the vehicle-stage
badge, shows a car icon with “车辆行驶中”, and replaces current speed with the
live cumulative distance. App launch and each foreground restoration refresh
the live vehicle dashboard; optional travel and BMS details hydrate in the
background without delaying the first screen.

首页里程卡片显示今日里程；充电详情在后台补抓电池诊断数据，并提供充电功率曲线卡片。

Web 版本 **v32** 在充电记录页加入通栏“充电功率曲线”卡片：使用 Tailwind 深色毛玻璃卡片与纯 SVG 平滑面积图，支持实时功率、峰值/平均功率、时间轴、悬浮/键盘数据点，以及移动端响应式布局。构建 Web 版本：`cd web && npm run build`。

GitHub Actions builds an unsigned device IPA and uploads it to workflow
artifacts. Pushing tag `v46` also creates or updates the matching GitHub Release
with the IPA and its SHA-256 checksum. The workflow uses the repository
`GITHUB_TOKEN` by default; if repository policy prevents release creation, add a
fine-grained `GH_RELEASE_TOKEN` Actions secret with repository **Contents: Read
and write** permission. Release-upload failures are reported as workflow
failures rather than being silently ignored.

For a local package, use Xcode 16.4 or newer:

```bash
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer \
  scripts/package-unsigned-ipa.sh --output build/ipa-v46 --derived-data build/DerivedData-v46
```

## v46 记录月份筛选修复

- 修复切换记录月份时无法获取其他月份数据的问题：原逻辑使用单一全局同步状态，当前月份请求尚未结束时，用户切换到其他月份会被直接丢弃；现在按“车辆 + 月份”分别跟踪请求，历史月份切换不会再被前一个月份阻塞。
- 月份筛选的加载状态改为只绑定当前车辆和当前月份，切换月份后会立即发起对应月份的真实云端请求，并保留已有归档数据。
- 删除月份筛选中的重复并发请求，避免“获取上一月份”按钮和 SwiftUI 页面任务同时请求同一个月份；App 与 Widget 的 Marketing Version / Build 均升级为 **46**，推送 `v46` 标签会由 GitHub Actions 打包 unsigned IPA、上传 Actions Artifact，并发布 IPA 与 SHA-256 到 GitHub Release。

## v45 记录页打开流畅性优化

- 修复打开「记录」页的明显卡顿：行程归档改为内存缓存读取，避免 SwiftUI 首屏和重绘时反复从 UserDefaults 解码、去重和排序数百条真实骑行数据。
- 月份筛选和行程日期格式化复用 formatter，列表采用惰性布局；首屏只构建可见行程行，历史月份继续使用真实开始时间显示。
- 行程云端同步改为记录页独立的非阻塞任务，先完成 Tab 切换和首帧渲染，不再切换全局 loading 状态；首批真实记录到达即显示，剩余分页仍在后台补齐。
- 写入行程归档后直接复用已规范化的内存结果，避免再次读取并解码同一份 JSON；iOS App 与 Widget 的 Marketing Version / Build 均升级为 **45**，推送 `v45` 标签会由 GitHub Actions 打包 unsigned IPA、上传 Actions Artifact，并发布 IPA 与 SHA-256 到 GitHub Release。

## v44 历史月份行程与启动同步优化

- 修复 `2026.07`、`2026.06` 等历史月份行程响应嵌套、真实开始时间解析和本地归档显示问题；月份页面从持久化行程归档读取并去重，避免主页刷新后历史月份消失。
- 历史月份首屏改为单页快速请求，先显示已获取的真实行程，再后台补齐后续分页；无法识别真实开始时间时不伪造日期，并保留重试。
- 启动时先显示本地缓存，车辆行程与电池详情并发同步，选中车辆优先更新；反向地理编码、图片和非首屏数据移到后台，目标在 3–5 秒内完成真实首页状态更新。
- iOS App 与 Widget 的 Marketing Version / Build 均升级为 **44**；推送 `v44` 标签会由 GitHub Actions 打包 unsigned IPA、上传 Actions Artifact，并发布 IPA 与 SHA-256 到 GitHub Release。

## v43 历史行程快速加载

- 修复“记录 / 行程”选择历史月份（例如 `2026.07`、`2026.06`）长时间停在加载状态的问题：前台只请求九号云的第一页真实行程，不再等待最多 99 个串行 `ninecli` 归档请求。
- 首批记录写入本地归档后立即显示；若该月还有更多页，App 会在后台逐页补齐，并检测上游重复页以避免无效循环或重复数据。
- 服务端 `travel-sync` 默认也改为快速首屏模式；只有显式传入 `complete=true` 的维护任务才会执行完整月归档，旧版 App 同样不会再等待两分钟。
- iOS App 与 Widget 的 Marketing Version / Build 均升级为 **43**；推送 `v43` 标签会由 GitHub Actions 打包 unsigned IPA，并将 IPA 与 SHA-256 发布到 GitHub Release。

## v42 本月总里程

- “行程”页的概要卡片将原来的“本月日均”替换为“本月总里程”，直接显示当前月 Ninebot 行程接口返回的真实 `total_mileages` / `monthMileage`，不会再以日期推算平均值。
- iOS App 与 Widget 的 Marketing Version / Build 均升级为 **42**；推送 `v42` 标签会由 GitHub Actions 打包 unsigned IPA，并将 IPA 与 SHA-256 发布到 GitHub Release。

## v41 首屏实时数据加载

- 修复自动启动/回到前台刷新：此前拿到实时车辆快照后还会同步等待图片下载和地址反查，且不会启动骑行/BMS 补全任务，造成车辆、电池与“今日里程”卡片长时间显示旧值或 `--`。现在快照会立即发布，耗时增强任务全部转入后台。
- 首页优先并发补全当前车辆的当前月骑行数据和 BMS 电池数据；今日里程、月统计、电压、温度、循环次数与充电功率会在补全后直接写回本地快照。
- 快速 Dashboard 响应不再覆盖已验证的本地骑行/BMS 数据，网络补全期间仍显示最近一次真实采样；`今日里程` 同日重复桶取最新累计值中较大的值，避免短暂回退。
- iOS App 与 Widget 的 Marketing Version / Build 均升级为 **41**；推送 `v41` 标签会由 GitHub Actions 构建 unsigned IPA、上传 Actions Artifact，并发布 IPA 与 SHA-256 到 GitHub Release。

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
