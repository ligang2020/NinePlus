# mini-ninebot

NineBot+ iOS app, **A1 UI redesign**, version **8** (build **8**).

The app's first screen is the **NinePlus account login**. The service URL can be
entered in the app, and an installation-wide Bearer Token can be supplied when
the backend enables API protection. The app stores only the returned per-user
NinePlus session token.

The app talks to the companion NinePlus service, which uses the community
`ninecli` cloud compatibility client. It is not an official public Ninebot
developer API. The official Ninebot cloud binding is configured once on the
server and reused by every device; the iOS app never asks each device for that
password. Cached vehicle data may be kept locally for a smoother dashboard.

## v5 首页状态与记录主题

- 首页已移除「骑行模式」入口卡片；车辆大卡片按静止、行驶、充电状态显示对应内容。
- 车辆未锁且未充电时统一显示为「车辆正在行驶中」；即使当前速度为 0，也不会错误显示为停稳/停车状态。
- 车辆大卡片在浅色模式使用明亮车辆素材，深色模式保留夜间素材；静止状态移除位置与地图入口，行驶状态移除底部骑行文案并显示 D 挡位，充电状态移除底部信息。
- 行程记录保留静态轨迹、起终点和速度分段信息，移除行程轨迹回放控件。
- GitHub Actions 会将 unsigned IPA 上传为 Actions artifact；推送 `v5` 标签时同步发布到 GitHub Release。

## A1 全局 UI 重构（Apple 磨砂玻璃风格）

- NinePlus 主界面、车辆状态、车辆概览、行程入口和车辆详情统一采用 Apple 风格的 Material 磨砂玻璃层级。
- 保留原有登录、Bearer Token、车辆控制、充电反馈、地图、行程、报警和推送功能；本次只调整视觉层、背景、间距、层级和反馈表现。
- 主仪表盘加入轻量连接状态顶栏、动态光晕背景、玻璃表面和更清晰的车辆状态层级。
- 不增加蓝牙能力；动画继续遵守“减少动态效果”系统设置，避免使用高频复杂粒子造成卡顿。

## v11 行驶状态与前台强制刷新

- 车辆行驶时，车辆舞台左上角只保留“车辆正在行驶中”文字，不再显示骑行图标。
- 下方“车辆状态”卡片使用汽车图标并显示“车辆行驶中”；原“当前时速”卡片改为“已行驶”，展示实时累计里程。
- 除 SwiftUI `scenePhase` 外，App 也监听 UIKit 的激活通知；若前一笔静默请求和前台恢复重叠，会在其完成后补发一次强制刷新。
- iOS App 与 Widget 扩展的营销版本和构建号均为 **11**；GitHub Actions 默认发布标签为 `v11`。

## v20 启动刷新与更新时间修复

- App 启动、回到前台和登录完成后都会立即发起一次车况刷新；启动请求遇到短暂网络唤醒失败会自动重试一次。
- URLSession 的车况请求强制绕过本地 HTTP 缓存，服务端返回的更新时间会用于卡片显示。
- 自动刷新失败时保留旧车况但明确标记“显示缓存”，避免手机时间已经变化而页面仍无提示。

## v19 车辆落地感修复

- 充电场景的官方车辆图片下移至庭院地面，并将原来距离车轮较远的大阴影改为与前、后轮精准对齐的接地阴影。
- 进一步降低车辆外层投影的偏移和模糊，车轮在实拍庭院地面上具有更明确的落地接触感，不再显得悬浮。
- 充电桩调整为右侧外墙上的壁挂式设备，取消落地支架；增加一根从桩体下方沿地面弧线连接至车辆后侧充电口的线缆。线缆层位于车辆图片后方，中段会自然被车身遮挡，不会横穿车辆。

## v18 实拍别墅后院充电场景

- 充电卡片改用实拍别墅后院背景：白天和夜晚使用不同的场景图自动切换，移除旧的卡通房屋和道路元素；白天不增加人工灯光，夜景保留别墅的自然室内与庭院灯光。
- 车辆继续使用官方接口图片，并缩小、左移，使其与右侧独立充电桩明确分离，不再发生重叠。
- 充电桩改为整洁的独立壁挂 / 落地式设备，充电线仅收纳在桩体上，不再横跨车辆或形成杂乱线条。

## v17 充电别墅场景与行程轨迹修复

- 充电状态使用别墅庭院场景：保留官方接口返回的车辆图片，新增充电桩和连接线，并依据天气接口的昼夜状态自动切换日景 / 夜景；日景不显示庭院灯，夜景显示暖色路径灯。
- 充电时主卡片将“接口续航”替换为“充电功率”，将“最高速度”替换为“电池温度”；“正在充电”下方显示预计充满所需时间和预计完成时刻。
- 行程详情直接使用后端标准化后的 GCJ-02 轨迹，避免再次进行 WGS-84 → GCJ-02 转换造成路线整体偏移。
- 当九号云逐点速度缺失、过少或重复时，地图会使用定位点间距和行程时长补全速度颜色；同时过滤异常 GPS 跳点，避免出现跨地图的错误直线。

## v16 前台刷新与更新时间

- 主车辆卡片始终显示本次 App 数据更新时间；后台静默更新时会显示“正在更新…”。
- App 每次启动和重新回到前台都会立即请求最新车况，不再因上次前台会话的节流而跳过。
- App 仅在前台轮询：充电中每 3 秒更新一次，其他状态每 6 秒更新一次；进入后台或非活跃状态立即停止轮询。

## v15 行程加载与打包版本更新

- 仪表盘接口默认优先返回车辆、实时状态和电池信息，行程历史改为按需加载，避免首次打开被较慢的行程接口阻塞。
- App 前台静默刷新复用后端短缓存；用户主动下拉刷新仍会请求最新车况。
- App 首屏保持快速加载车辆状态，当前月份骑行行程在后台并行补全并写入缓存；修复后端 dashboard 默认不返回 travel 导致行程页为空的问题。GitHub Actions 默认发布标签更新为 `v15`，会上传 unsigned IPA 和 SHA-256 校验文件，并在推送 `v15` 标签时发布到 GitHub Release。

## v13 充电主页与刷新优化

- 充电状态复用“车辆已停稳”的静态场景，并在车辆右侧增加已连接的充电桩和静态充电线；不再使用独立的科技网格背景。
- 充电页面保留电量、预计充满与充电功率信息，并继续提供完整车辆控制、位置、行程、电池、车辆信息、多车辆概览和底部 Tab。
- 仪表盘拿到车辆快照后会立即保存并显示；图片下载和地址反查改为可取消的并行后台补全，不再拖慢首次打开 App、下拉刷新、登录和控制指令后的车况更新。
- App 回到前台时会使用短节流避免与启动任务重复请求同一份车辆数据。
- 修复 AppIcon 资源清单，补齐 iPhone / iPad 所需尺寸，确保安装后可正常显示应用图标。


## v8 日夜车辆素材切换

- 车辆已停稳、车辆正在行驶中和正在充电三种状态均按本地时间自动切换白天 / 夜间图片。
- 白天时段定义为每天 06:00–18:59，避免早上 06:00 仍被天气接口的日出判断锁在夜间素材。
- GitHub Actions 使用 `v8` 版本构建 unsigned IPA，并将 IPA 和 SHA-256 校验文件上传到 Actions artifact；推送 `v8` 标签时同步上传到 GitHub Release。

## v9 地图卡片定位修复

- 首页地图卡片将车辆 WGS-84 定位转换为 MapKit 使用的 GCJ-02，并在刷新后同步更新地图中心与标记。
- GitHub Actions 使用 `v9` 版本构建 unsigned IPA，并将 IPA 和 SHA-256 校验文件上传到 Actions artifact；推送 `v9` 标签时同步上传到 GitHub Release。


## v9 行程详情

- 行程详情会显示轨迹起点、终点的反向地理编码地址和对应时间；无网络或无法解析时回退显示坐标。
- 轨迹线按速度分段着色：九号云返回逐点速度时优先采用真实值；如果上游只返回定位坐标，App 会按相邻定位点间距与行程总时长估算速度并明确标注为“估算”，避免整条路线退回默认绿色。颜色范围为蓝色（0–10 km/h）、青色（10–25 km/h）、绿色（25–40 km/h）、橙色（40–55 km/h）、红色（55+ km/h）。
- 保留静态轨迹地图、起终点地址和速度分段展示。

## 配置服务器地址并连接 App

当前 A1 / v14 App 支持在登录页和「我的 → 服务器连接」中修改后端地址。地址只需要填写协议、主机和端口，不要附加 `/healthz` 或其他接口路径：

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
