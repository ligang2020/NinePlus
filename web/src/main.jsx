import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import {
  Activity,
  AlertTriangle,
  ArrowLeft,
  ArrowRight,
  BatteryCharging,
  Bell,
  Bluetooth,
  CalendarDays,
  CarFront,
  ChevronDown,
  ChevronRight,
  CircleGauge,
  Cloud,
  CloudSun,
  Check,
  Crosshair,
  Database,
  Eye,
  Fingerprint,
  Gauge,
  Lock,
  LocateFixed,
  MapPin,
  Moon,
  Navigation,
  Package,
  Pause,
  Play,
  Power,
  Radio,
  Route,
  SlidersHorizontal,
  ScanLine,
  Search,
  Settings,
  ShieldCheck,
  Sparkles,
  Sun,
  Thermometer,
  TriangleAlert,
  Timer,
  Unlock,
  UserCircle,
  Wind,
  Wrench,
  Zap,
} from 'lucide-react';
import './styles.css';

const tabs = [
  { id: 'control', label: '车控', icon: CarFront },
  { id: 'trips', label: '行程', icon: Route },
  { id: 'records', label: '记录', icon: CircleGauge },
  { id: 'security', label: '安全', icon: ShieldCheck },
  { id: 'profile', label: '我的', icon: UserCircle },
];

const trips = [
  { date: '2026-08-12 16:09', end: '16:19', duration: '10 分钟', distance: '1.3 km', speed: '46 km/h', energy: '0 Wh', start: '连通港西路 13 号', finish: '杨泗港快速路' },
  { date: '2026-08-11 19:42', end: '20:06', duration: '24 分钟', distance: '8.6 km', speed: '52 km/h', energy: '118 Wh', start: '汉阳大道', finish: '鹦鹉洲大桥' },
  { date: '2026-08-09 08:18', end: '08:47', duration: '29 分钟', distance: '12.8 km', speed: '61 km/h', energy: '176 Wh', start: '墨水湖边', finish: '武汉天地' },
];

const alarms = [
  { title: '车辆移动报警', detail: '检测到车辆发生轻微移动，请确认车辆停放环境。', time: '2026-08-12 21:18', place: '连通港西路 13 号', tone: 'red' },
  { title: '低电量提醒', detail: '电池电量低于 20%，建议及时充电。', time: '2026-08-08 18:32', place: '汉阳大道附近', tone: 'orange' },
];

const charges = [
  { start: '2026-08-11 22:06', end: '2026-08-12 01:12', duration: '3 小时 06 分钟', power: '186 W', temp: '31°C', voltage: '58.4 V', place: '家 · 地下车库' },
  { start: '2026-08-05 21:44', end: '2026-08-06 00:18', duration: '2 小时 34 分钟', power: '204 W', temp: '29°C', voltage: '58.1 V', place: '公司停车区' },
];

function cn(...classes) { return classes.filter(Boolean).join(' '); }
function formatNow() { return new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit' }).format(new Date()); }

function Card({ children, className = '', onClick, as = 'section' }) {
  const Component = as;
  return <Component onClick={onClick} className={cn('ios-card', onClick && 'cursor-pointer active:scale-[0.99] transition-transform', className)}>{children}</Component>;
}

function SectionTitle({ eyebrow, title, action, onAction }) {
  return <div className="flex items-end justify-between gap-3 px-1">
    <div><p className="ios-eyebrow">{eyebrow}</p><h2 className="ios-section-title">{title}</h2></div>
    {action && <button onClick={onAction} className="ios-link">{action}<ChevronRight size={18} /></button>}
  </div>;
}

function BottomNav({ current, onChange }) {
  return <nav className="bottom-nav" aria-label="主导航">
    {tabs.map(({ id, label, icon: Icon }) => {
      const active = id === current;
      return <button key={id} onClick={() => onChange(id)} className={cn('bottom-nav-item', active && 'active')} aria-current={active ? 'page' : undefined}>
        <Icon size={25} strokeWidth={active ? 2.7 : 2.1} /><span>{label}</span>
      </button>;
    })}
  </nav>;
}

function Header({ title, back, onBack, trailing }) {
  return <header className="sticky top-0 z-20 flex h-[76px] items-center justify-between bg-[#f2f2f7]/90 px-5 backdrop-blur-xl">
    <div className="min-w-[72px]">{back && <button onClick={onBack} className="flex items-center gap-1 text-[17px] font-medium text-[#1dcc50]"><ArrowLeft size={25} />返回</button>}</div>
    <h1 className="text-[24px] font-bold tracking-[-0.04em] text-[#111318]">{title}</h1>
    <div className="flex min-w-[72px] justify-end">{trailing}</div>
  </header>;
}

function StatusPill({ children, tone = 'green', icon: Icon = ShieldCheck }) {
  return <span className={cn('status-pill', tone === 'green' ? 'status-pill-green' : 'status-pill-neutral')}><Icon size={17} fill={tone === 'green' ? 'currentColor' : 'none'} />{children}</span>;
}

function MiniMetric({ icon: Icon, value, label, accent = false }) {
  return <div className="mini-metric"><div className={cn('mini-metric-icon', accent && 'text-[#1dcc50]')}><Icon size={20} /></div><strong>{value}</strong><span>{label}</span></div>;
}

function MapWidget({ compact = false, onOpen }) {
  return <Card onClick={onOpen} className={cn('map-widget overflow-hidden p-0', compact ? 'min-h-[214px]' : 'min-h-[310px]')}>
    <div className="map-surface">
      <div className="map-road road-one" /><div className="map-road road-two" /><div className="map-road road-three" /><div className="map-water" />
      <span className="map-label label-a">杨泗港快速路</span><span className="map-label label-b">梅林一街</span><span className="map-label label-c">汉阳 · 漾</span>
      <div className="map-pin"><Navigation size={19} fill="white" /></div>
      <div className="map-ripple" />
      <div className="map-bottom-label"><MapPin size={17} />{compact ? '连通港西路 13 号' : '车辆当前位置 · 已更新'}</div>
    </div>
  </Card>;
}

function ControlPage({ onNavigate }) {
  const [unlocked, setUnlocked] = useState(false);
  const [actionMessage, setActionMessage] = useState('滑动解锁');
  const [weather, setWeather] = useState({ temp: 26, wind: 5, uv: 0 });
  useEffect(() => {
    const timer = window.setInterval(() => setWeather((value) => ({ ...value, wind: value.wind === 5 ? 6 : 5 })), 5000);
    return () => window.clearInterval(timer);
  }, []);
  const perform = (label) => { setActionMessage(`${label}已完成`); window.setTimeout(() => setActionMessage('滑动解锁'), 1600); };
  return <div className="page-stack">
    <div className="flex items-start justify-between px-1 pt-4">
      <div><div className="flex items-center gap-2"><h1 className="text-[29px] font-bold tracking-[-0.06em]">B2轰炸机</h1><ChevronDown size={22} className="text-gray-400" /></div><p className="mt-1 text-[16px] font-medium text-gray-500">Mz MAX (14360)</p><p className="mt-1 text-[14px] text-gray-500">连通港西路 13 号 · 连通港西路 · 武汉市 · 湖北省 · 中国</p></div>
      <StatusPill>已上电</StatusPill>
    </div>
    <div className="pt-4 text-center"><div className="hero-range">218.7<span>km</span></div><p className="mt-1 text-[17px] font-semibold text-gray-500">预计可行驶</p></div>
    <Card className="vehicle-card relative overflow-hidden p-0">
      <div className="vehicle-scene"><div className="scene-skyline" /><div className="scene-lamps"><i /><i /><i /><i /></div><div className="scene-road" /><div className="scene-road-lines"><i /><i /><i /><i /></div><div className="scene-glow" />
        <div className="vehicle-state">车辆已停稳 · 已上电</div>
        <div className="weather-glass"><div><Thermometer size={17} />气温 <b>{weather.temp}°</b></div><div><Wind size={17} />风速 <b>{weather.wind} km/h</b></div><div><Sun size={17} />紫外线 <b>{weather.uv}</b></div><div><CloudSun size={17} />空气质量 <b>良 72</b></div></div>
        <img src="/scooter.png" alt="九号电动车" className="vehicle-art" />
      </div>
      <div className="battery-progress"><div style={{ width: '96%' }} /></div>
    </Card>
    <div className="grid grid-cols-3 gap-2.5"><MiniMetric icon={BatteryCharging} value="96%" label="电量" accent /><MiniMetric icon={Route} value="256.6 km" label="接口续航" /><MiniMetric icon={Gauge} value="68 km/h" label="最高速度" /></div>
    <Card className="control-center p-3"><button className="control-round" onClick={() => perform('寻车')}><Bell size={27} fill="currentColor" /><span>寻车</span></button><button className={cn('unlock-track', unlocked && 'is-unlocked')} onClick={() => { setUnlocked((value) => !value); perform(unlocked ? '已上锁' : '解锁'); }}><span className="unlock-knob">{unlocked ? <Unlock size={23} /> : <Lock size={23} />}</span><strong>{unlocked ? '已解锁' : actionMessage}</strong><ArrowRight size={28} className="text-[#1dcc50]" /></button><button className="control-round" onClick={() => perform('座桶')}><Package size={27} fill="currentColor" /><span>座桶</span></button></Card>
    <div className="grid grid-cols-2 gap-3"><div><SectionTitle eyebrow="位置" title="车辆位置" action="" /><MapWidget compact onOpen={() => onNavigate('security')} /></div><Card className="trip-widget p-4" onClick={() => onNavigate('trips')}><div className="flex items-center justify-between"><div className="flex items-center gap-2"><Route size={22} /><h2 className="text-[20px] font-bold">行程</h2></div><ChevronRight className="text-gray-500" /></div><div className="trip-highlight"><span>最近骑行</span><strong>1.3 <small>km</small></strong></div><div className="trip-total"><span>总行程</span><strong>594 <small>km</small></strong></div></Card></div>
  </div>;
}

function OverviewCard({ onTrend }) {
  return <Card className="p-5"><div className="flex items-start justify-between"><div><h2 className="text-[28px] font-bold tracking-[-0.05em]">行程概要</h2><p className="text-[17px] font-medium text-gray-500">B2轰炸机</p></div><div className="text-right"><strong className="text-[38px] font-bold tracking-[-0.06em] text-[#1dcc50]">76%</strong><p className="text-[15px] font-medium text-gray-500">预计准确率</p></div></div><div className="mt-8 flex items-end gap-3"><strong className="text-[70px] font-bold leading-[0.82] tracking-[-0.09em]">218.7</strong><span className="mb-1 text-[21px] font-medium">km</span><span className="mb-1 text-[17px] font-medium text-gray-500">预计可行驶</span></div><div className="mt-8 grid grid-cols-2 gap-3"><div className="trip-stat"><span><CarFront size={19} /></span><strong>594 km</strong><small>车辆总里程</small></div><div className="trip-stat"><span><Sun size={19} /></span><strong>20.8 km</strong><small>今日里程</small></div><div className="trip-stat"><span><Gauge size={19} /></span><strong>68 km/h</strong><small>最高速度</small></div><div className="trip-stat"><span><CalendarDays size={19} /></span><strong>46 km/日</strong><small>本月日均</small></div></div><div className="mt-5 flex items-center gap-2 text-[15px] font-semibold text-gray-500"><Crosshair size={19} />本地模型 · 7 次有效行程</div></Card>;
}

function TripItem({ trip, onClick }) {
  return <Card onClick={onClick} className="p-4"><div className="flex items-start gap-3"><div className="trip-icon"><Route size={22} /></div><div className="min-w-0 flex-1"><div className="flex items-start justify-between gap-2"><div><strong className="block text-[18px] tracking-[-0.03em]">{trip.date}</strong><span className="mt-1 block text-[14px] font-medium text-gray-500">结束 {trip.end} · {trip.duration}</span></div><strong className="whitespace-nowrap text-[24px] tracking-[-0.05em]">{trip.distance}</strong></div><div className="mt-4 grid grid-cols-2 gap-2 text-[13px] text-gray-500"><span className="flex items-center gap-1"><MapPin size={14} />{trip.start}</span><span className="flex items-center gap-1"><FlagIcon />{trip.finish}</span></div><div className="mt-3 flex gap-2"><span className="soft-chip">最高 {trip.speed}</span><span className="soft-chip">用电 {trip.energy}</span></div></div></div></Card>;
}
function FlagIcon() { return <span className="inline-flex h-3 w-3 items-center justify-center rounded-full bg-[#1dcc50]" />; }

function TripsPage({ onBackDetail }) {
  const [month, setMonth] = useState('2026.08');
  return <div className="page-stack"><Header title="行程" trailing={<button className="header-icon"><Search size={21} /></button>} /><OverviewCard /><Card onClick={onBackDetail} className="flex items-center gap-4 p-4"><div className="trend-icon"><Activity size={27} /></div><div className="flex-1"><strong className="block text-[21px]">查看趋势</strong><span className="text-[15px] font-medium text-gray-500">里程、用电、速度和续航估算表现</span></div><div className="text-right"><strong className="text-[22px]">552.5 km</strong><ChevronRight className="ml-auto text-gray-500" /></div></Card><Card className="p-5"><div className="flex items-start justify-between"><div><h2 className="text-[22px] font-bold">月份筛选</h2><p className="mt-1 text-[15px] text-gray-500">当前 2026.08</p></div><button onClick={() => setMonth('2026.07')} className="month-fetch"><Activity size={17} />获取 2026.07</button></div><button onClick={() => setMonth(month === '2026.08' ? '2026.07' : '2026.08')} className="month-pill">{month}</button></Card><div className="flex items-end justify-between px-1"><div><h2 className="ios-section-title">行程列表</h2><p className="text-[15px] font-medium text-gray-500">点击行程查看接口详情与官方轨迹</p></div><strong className="text-[39px] tracking-[-0.08em] text-gray-500">20</strong></div><div className="space-y-3">{trips.map((trip) => <TripItem key={trip.date} trip={trip} onClick={onBackDetail} />)}</div></div>;
}

function TrendPage({ onBack, onTripDetail }) {
  const bars = [38.7, 61.8, 56.8, 120, 67.1, 67.5, 25.8, 0, 0, 65.9, 28.2, 20.8];
  return <div className="page-stack"><Header title="趋势分析" back onBack={onBack} /><Card className="p-5"><div className="flex items-start justify-between"><div><h2 className="text-[25px] font-bold">B2轰炸机</h2><p className="text-[16px] text-gray-500">趋势分析</p></div><div className="text-right"><strong className="text-[38px] text-[#1dcc50]">76%</strong><p className="text-gray-500">预计准确率</p></div></div><div className="mt-8"><strong className="text-[65px] leading-none tracking-[-0.09em]">552.5</strong><span className="ml-2 text-[23px]">km</span><p className="mt-2 text-[17px] text-gray-500">当月行程</p></div><div className="mt-7 grid grid-cols-3 gap-3"><div className="trend-stat"><strong>20</strong><span>骑行次数</span></div><div className="trend-stat"><strong>12</strong><span>活跃天数</span></div><div className="trend-stat"><strong>15.2</strong><span>Wh/km</span></div></div></Card><Card className="p-5"><div className="flex items-start justify-between"><div><h2 className="text-[24px] font-bold">本地续航模型</h2><p className="text-[15px] text-gray-500">样本波动较大，已降低本地模型权重。</p></div><strong className="text-[25px]">218.7 km</strong></div><div className="mt-5 grid grid-cols-2 gap-3"><div className="trend-tile"><strong>76%</strong><span>准确率</span></div><div className="trend-tile"><strong>7 次</strong><span>有效样本</span></div><div className="trend-tile"><strong>2.67 km/%</strong><span>近期效率</span></div><div className="trend-tile"><strong>256.6 km</strong><span>接口续航</span></div></div></Card><Card className="p-5"><div className="flex items-end justify-between"><div><h2 className="text-[24px] font-bold">每日里程趋势</h2><p className="text-[15px] text-gray-500">最近 12 天</p></div><strong className="text-[28px] text-[#1dcc50]">119.9 km</strong></div><div className="bar-chart">{bars.map((height, index) => <div key={index} className="bar-column"><span>{height}</span><i style={{ height: `${Math.max(8, (height / 120) * 100)}%` }} /></div>)}</div></Card><Card onClick={onTripDetail} className="p-5"><div className="flex items-center justify-between"><div><h2 className="text-[22px] font-bold">最新行程</h2><p className="mt-1 text-gray-500">2026-08-12 · 1.3 km</p></div><ChevronRight className="text-gray-500" /></div></Card></div>;
}

function TripDetailPage({ onBack }) {
  return <div className="page-stack"><Header title="行程详情" back onBack={onBack} /><Card className="p-5"><div className="flex items-start justify-between"><div><strong className="text-[24px]">2026-08-12 16:09</strong><p className="mt-1 text-[17px] text-gray-500">结束 16:19</p></div><Route size={40} className="text-[#1dcc50]" /></div><strong className="mt-8 block text-[74px] leading-none tracking-[-0.09em]">1.3<span className="ml-1 text-[26px] tracking-normal">km</span></strong><div className="mt-8 grid grid-cols-2 gap-3"><div className="trip-detail-chip"><Timer size={18} /><strong>10 分钟</strong><span>骑行时间</span></div><div className="trip-detail-chip"><Gauge size={18} /><strong>46 km/h</strong><span>最高速度</span></div><div className="trip-detail-chip"><Zap size={18} /><strong>0 Wh</strong><span>本次用电</span></div><div className="trip-detail-chip"><Activity size={18} /><strong>0 Wh/km</strong><span>能耗</span></div></div></Card><Card className="p-4"><div className="flex items-start justify-between px-1"><div><h2 className="text-[22px] font-bold">官方接口轨迹</h2><p className="mt-1 text-[15px] text-gray-500">起点 → 终点 · 官方接口返回 23 个路线点</p></div><span className="speed-legend"><Sparkles size={16} />接口速度</span></div><div className="trajectory-map"><div className="trajectory-road one" /><div className="trajectory-road two" /><div className="trajectory-road three" /><div className="trajectory-route route-green" /><div className="trajectory-route route-red" /><div className="trajectory-pin start"><span>⚑</span><b>起点</b></div><div className="trajectory-pin peak"><strong>最高速度<br />46.0 km/h</strong></div><div className="trajectory-pin end"><span>⌖</span><b>终点</b></div></div><div className="trajectory-footer"><span>🚩 仅按接口明确返回…</span><strong>最高 46.0 km/h</strong><span>0 <i /></span><span>40+ km/h</span></div></Card><div className="px-1"><h2 className="ios-section-title">接口行程</h2><div className="detail-row"><Play size={18} fill="currentColor" /><span>开始时间</span><strong>2026-08-12 16:09</strong></div><div className="detail-row"><Pause size={18} fill="currentColor" /><span>结束时间</span><strong>2026-08-12 16:19</strong></div></div></div>;
}

function ProfilePage({ onRecords, onOpenSettings }) {
  return <div className="page-stack"><Header title="我的" trailing={<button type="button" className="header-icon" onClick={onOpenSettings} aria-label="打开设置"><Settings size={21} /></button>} /><Card className="profile-card p-5"><div className="profile-avatar">李</div><div className="min-w-0 flex-1"><h2 className="text-[24px] font-bold">李易峰的电瓶车</h2><p className="mt-1 text-[16px] text-gray-500">服务器 · B2轰炸机</p></div><span className="profile-count">2</span></Card><Card className="p-5"><div className="flex items-start justify-between"><div><h2 className="text-[23px] font-bold">车辆名称</h2><p className="mt-1 max-w-[280px] text-[15px] leading-6 text-gray-500">名称会同步用于主 App、小组件和灵动岛；不会修改车辆原始编号。</p></div><span className="tag-icon"><Wrench size={20} /></span></div><VehicleRow name="B2轰炸机" model="Mz MAX (14360)" /><VehicleRow name="特斯拉 YYDS" model="Ninebot eMoped F35 (117)" /></Card><Card className="p-5"><div className="flex gap-4"><div className="bluetooth-icon"><Bluetooth size={26} /></div><div className="flex-1"><h2 className="text-[23px] font-bold">车辆蓝牙（安全只读）</h2><p className="mt-1 text-[16px] text-gray-500">等待授权车辆配置</p></div></div><p className="mt-3 text-[14px] leading-6 text-gray-500">尚未提供官方 GATT 服务、特征和认证适配器</p><div className="mt-4 flex flex-wrap gap-x-4 gap-y-2 text-[14px] font-semibold text-gray-500"><span>♨ 不自动连接</span><span>🔒 不发送控制</span><span>⌁ 只订阅遥测</span></div><button className="scan-button"><Radio size={20} />扫描附近设备</button><p className="mt-3 text-[13px] leading-5 text-gray-500">扫描结果仅在本次运行中显示。未配置厂商授权的 GATT 服务、遥测特征、解码器和受信任外设识别前，App 不会连接任何车辆。</p></Card><RecordLink icon={AlertTriangle} title="车辆报警记录" subtitle="已记录 1 条异常事件" badge="1" tone="red" onClick={() => onRecords('alarms')} /><RecordLink icon={BatteryCharging} title="充电记录" subtitle="2 条完整充电周期" onClick={() => onRecords('charging')} /><Card className="flex items-center gap-3 p-4"><div className="text-[#1dcc50]"><ShieldCheck size={25} /></div><div><strong className="block text-[16px] text-[#1dcc50]">已更新 {formatNow()}</strong><span className="text-[13px] text-gray-500">车辆与记录数据已同步</span></div></Card></div>;
}

function SettingsRow({ icon: Icon, title, subtitle, value, tone = 'neutral', onClick, children }) {
  const content = <>
    <span className={cn('settings-row-icon', `settings-row-icon-${tone}`)}><Icon size={19} /></span>
    <span className="settings-row-copy"><strong>{title}</strong>{subtitle && <small>{subtitle}</small>}</span>
    {children ? <span className="settings-row-control">{children}</span> : (value && <span className="settings-row-value">{value}</span>)}
    {onClick && <ChevronRight className="settings-row-chevron" size={19} />}
  </>;
  return onClick
    ? <button type="button" onClick={onClick} className="settings-row">{content}</button>
    : <div className="settings-row">{content}</div>;
}

function SettingsToggle({ checked, onChange, label }) {
  return <button type="button" onClick={() => onChange(!checked)} className={cn('settings-toggle', checked && 'is-on')} role="switch" aria-checked={checked} aria-label={label}><span /></button>;
}

function SettingsPage({ onBack }) {
  const [addressLookup, setAddressLookup] = useState(true);
  const [lowBattery, setLowBattery] = useState(true);
  const [backgroundRefresh, setBackgroundRefresh] = useState(true);
  const [privacyShield, setPrivacyShield] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [notice, setNotice] = useState('所有服务运行正常');
  const refresh = () => {
    if (isRefreshing) return;
    setIsRefreshing(true);
    setNotice('正在验证连接…');
    window.setTimeout(() => { setIsRefreshing(false); setNotice(`连接正常 · 刚刚更新 ${formatNow()}`); }, 850);
  };
  const requestSignOut = () => {
    if (window.confirm('确定要退出当前 NinePlus 账户吗？本地缓存会保留在设备上。')) setNotice('已退出演示账户');
  };
  return <div className="page-stack settings-page">
    <Header title="设置" back onBack={onBack} />
    <Card className="settings-connection-card p-5">
      <div className="settings-connection-header"><span className="settings-connection-icon"><Cloud size={25} /></span><div><p className="ios-eyebrow">NINEPLUS PLATFORM</p><h2>已连接</h2></div><span className="settings-live-dot"><i />在线</span></div>
      <p className="settings-endpoint">nineplus.example.com · HTTPS</p>
      <div className="settings-connection-footer"><span><Check size={16} />{notice}</span><button type="button" onClick={refresh} disabled={isRefreshing}>{isRefreshing ? '检查中' : '检查连接'}</button></div>
    </Card>

    <div className="settings-section"><SectionTitle eyebrow="偏好设置" title="车辆与提醒" />
      <Card className="settings-list">
        <SettingsRow icon={MapPin} title="位置地址解析" subtitle="将经纬度转换为可读地址" tone="blue"><SettingsToggle checked={addressLookup} onChange={setAddressLookup} label="位置地址解析" /></SettingsRow>
        <SettingsRow icon={BatteryCharging} title="低电量提醒" subtitle="电量低于 20% 时通知我" tone="orange"><SettingsToggle checked={lowBattery} onChange={setLowBattery} label="低电量提醒" /></SettingsRow>
        <SettingsRow icon={Activity} title="后台自动刷新" subtitle="在合适的时机更新车辆状态" tone="green"><SettingsToggle checked={backgroundRefresh} onChange={setBackgroundRefresh} label="后台自动刷新" /></SettingsRow>
      </Card>
    </div>

    <div className="settings-section"><SectionTitle eyebrow="数据与隐私" title="设备保护" />
      <Card className="settings-list">
        <SettingsRow icon={Fingerprint} title="Face ID" subtitle="打开应用时验证身份" value="未启用" tone="purple" onClick={() => setNotice('Face ID 设置将在原生 App 中完成')} />
        <SettingsRow icon={Eye} title="隐藏敏感信息" subtitle="切换后台时隐藏车辆与账户信息" tone="purple"><SettingsToggle checked={privacyShield} onChange={setPrivacyShield} label="隐藏敏感信息" /></SettingsRow>
        <SettingsRow icon={Database} title="本地数据与诊断" subtitle="缓存、Widget 和原始字段" tone="neutral" onClick={() => setNotice('诊断中心已准备就绪')} />
      </Card>
    </div>

    <div className="settings-section"><SectionTitle eyebrow="关于" title="NineBot+" />
      <Card className="settings-list">
        <SettingsRow icon={SlidersHorizontal} title="应用设置" value="版本 1.2.69" tone="neutral" onClick={() => setNotice('当前已是最新版本')} />
        <SettingsRow icon={TriangleAlert} title="退出登录" subtitle="本地行程记录不会被删除" tone="red" onClick={requestSignOut} />
      </Card>
    </div>
    <p className="settings-footnote"><Moon size={14} />设置会保存在当前设备；同步数据时不会上传账户密码。</p>
  </div>;
}

function App() {
  const [tab, setTab] = useState('control');
  const [subView, setSubView] = useState(null);
  const navigate = (next) => { setSubView(null); setTab(next); window.scrollTo({ top: 0, behavior: 'smooth' }); };
  let content;
  if (subView === 'trend') content = <TrendPage onBack={() => setSubView(null)} onTripDetail={() => setSubView('detail')} />;
  else if (subView === 'detail') content = <TripDetailPage onBack={() => setSubView('trend')} />;
  else if (subView === 'records-alarms') content = <RecordsPage mode="alarms" onBack={() => setSubView(null)} />;
  else if (subView === 'records-charging') content = <RecordsPage mode="charging" onBack={() => setSubView(null)} />;
  else if (subView === 'settings') content = <SettingsPage onBack={() => setSubView(null)} />;
  else if (tab === 'control') content = <ControlPage onNavigate={navigate} />;
  else if (tab === 'trips') content = <TripsPage onBackDetail={() => setSubView('detail')} />;
  else if (tab === 'records') content = <RecordsPage mode="alarms" onBack={() => navigate('control')} />;
  else if (tab === 'security') content = <SecurityPage />;
  else content = <ProfilePage onRecords={(mode) => setSubView(`records-${mode}`)} onOpenSettings={() => setSubView('settings')} />;
  const activeTab = subView ? (subView.startsWith('records') || subView === 'settings' ? 'profile' : 'trips') : tab;
  return <div className="min-h-screen bg-[#f2f2f7] text-[#111318]"><main className="mobile-shell pb-28">{content}</main><BottomNav current={activeTab} onChange={navigate} /></div>;
}

createRoot(document.getElementById('root')).render(<App />);
