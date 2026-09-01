const $ = (selector) => document.querySelector(selector);

const state = {
  vehicles: [],
  selected: null,
  status: null,
  battery: null,
  travels: null,
  pendingAction: null,
};

const mapInstances = new Set();
const CHINA_MAP_TILE_URL = 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x={x}&y={y}&z={z}';
const FALLBACK_MAP_TILE_URL = 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';

const fieldSources = (object) => {
  if (!object || typeof object !== 'object') return [];
  const sources = [];
  const queue = [object];
  const seen = new Set();
  while (queue.length) {
    const source = queue.shift();
    if (!source || typeof source !== 'object' || seen.has(source)) continue;
    seen.add(source);
    sources.push(source);
    for (const key of ['data', 'result', 'payload', 'state', 'body', 'response']) {
      if (source[key] && typeof source[key] === 'object') queue.push(source[key]);
    }
  }
  return sources;
};

const fields = (object, keys, fallback = null) => {
  const sources = fieldSources(object);
  for (const key of keys) {
    for (const source of sources) {
      const value = key.split('.').reduce((current, part) => current?.[part], source);
      if (value !== undefined && value !== null && value !== '') return value;
    }
  }
  return fallback;
};

const unwrapArray = (value, keys = []) => {
  if (Array.isArray(value)) return value;
  for (const source of fieldSources(value)) {
    for (const key of keys) {
      const candidate = key.split('.').reduce((current, part) => current?.[part], source);
      if (Array.isArray(candidate)) return candidate;
    }
  }
  return [];
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    cache: 'no-store',
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.ok === false) {
    const message = payload.error?.message || payload.detail?.message || `请求失败 (${response.status})`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return payload.data ?? payload;
}

function toast(message) {
  const element = $('#toast');
  element.textContent = message;
  element.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove('show'), 2600);
}

function setAuthenticated(authenticated) {
  $('#loginView').hidden = authenticated;
  $('#appView').hidden = !authenticated;
}

function showPortalLogin() {
  $('#loginForm').hidden = false;
}

function setBusy(button, busy, label) {
  button.disabled = busy;
  if (!button.dataset.label) button.dataset.label = button.querySelector('span')?.textContent || button.textContent;
  const labelElement = button.querySelector('span');
  if (labelElement) labelElement.textContent = busy ? label : button.dataset.label;
  else button.textContent = busy ? label : button.dataset.label;
}

function vehicleSN(vehicle) {
  return String(fields(vehicle, ['sn', 'wnumber', 'serial_number', 'serialNumber'], ''));
}

function vehicleName(vehicle) {
  return fields(vehicle, ['name', 'device_name', 'deviceName', 'ble_name'], vehicleSN(vehicle) || '九号车辆');
}

function numberValue(value) {
  if (typeof value === 'boolean' || value === null || value === undefined || value === '') return null;
  const parsed = Number(String(value).replace(',', '.'));
  return Number.isFinite(parsed) ? parsed : null;
}

function number(value, suffix = '', digits = 0) {
  const parsed = numberValue(value);
  return parsed === null ? '--' : `${parsed.toFixed(digits)}${suffix}`;
}

function textValue(value, fallback = '--') {
  if (value === null || value === undefined || value === '') return fallback;
  if (typeof value === 'object') return fallback;
  return String(value);
}

function booleanValue(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value !== 'string') return null;
  return ['1', 'true', 'yes', 'on', 'charging', 'running', 'riding'].includes(value.toLowerCase())
    ? true
    : ['0', 'false', 'no', 'off', 'stopped', 'idle'].includes(value.toLowerCase()) ? false : null;
}

function coordinateFrom(value) {
  if (!value) return null;
  if (Array.isArray(value) && value.length >= 2) {
    const first = numberValue(value[0]);
    const second = numberValue(value[1]);
    if (first === null || second === null) return null;
    return Math.abs(first) > 90 && Math.abs(second) <= 90 ? [second, first] : [first, second];
  }
  if (typeof value === 'string') {
    const parts = value.split(/[,;|\s]+/).map(numberValue).filter((part) => part !== null);
    if (parts.length < 2) return null;
    return Math.abs(parts[0]) > 90 && Math.abs(parts[1]) <= 90 ? [parts[1], parts[0]] : [parts[0], parts[1]];
  }
  if (typeof value !== 'object') return null;
  const lat = numberValue(fields(value, ['lat', 'latitude', 'y', 'gcj02_lat', 'gcj02Lat']));
  const lng = numberValue(fields(value, ['lng', 'lon', 'longitude', 'x', 'gcj02_lng', 'gcj02Lng']));
  return lat !== null && lng !== null ? [lat, lng] : null;
}

function statusCoordinate(status) {
  const direct = coordinateFrom(fields(status, [
    'location_coordinate', 'locationCoordinate', 'location', 'loc', 'position', 'coordinates', 'coordinate',
  ]));
  if (direct) return direct;
  const lat = fields(status, ['lat', 'latitude', 'loc.lat', 'loc.latitude', 'location.lat', 'location.latitude', 'position.lat']);
  const lng = fields(status, ['lng', 'lon', 'longitude', 'loc.lon', 'loc.lng', 'loc.longitude', 'location.lng', 'location.lon', 'location.longitude', 'position.lng']);
  return coordinateFrom({ lat, lng });
}

function travelCoordinate(travel, kind) {
  const start = kind === 'start';
  const names = start ? {
    object: ['start', 'start_point', 'startPoint', 'start_location', 'startLocation', 'start_pos', 'startPos', 'start_coords', 'startCoords', 'origin', 'origin_location', 'from', 'begin'],
    pair: ['start_coordinate', 'startCoordinate', 'start_position', 'startPosition', 'start_point_latlng', 'startPointLatLng', 'origin_coordinate', 'from_coordinate'],
    lat: ['start_lat', 'startLat', 'start_latitude', 'startLatitude', 'start_point_lat', 'startPointLat', 'begin_lat', 'origin_lat', 'from_lat'],
    lng: ['start_lng', 'startLng', 'start_lon', 'startLon', 'start_longitude', 'startLongitude', 'start_point_lng', 'startPointLng', 'begin_lng', 'origin_lng', 'from_lng'],
  } : {
    object: ['end', 'end_point', 'endPoint', 'end_location', 'endLocation', 'end_pos', 'endPos', 'end_coords', 'endCoords', 'destination', 'destination_location', 'to', 'finish'],
    pair: ['end_coordinate', 'endCoordinate', 'end_position', 'endPosition', 'end_point_latlng', 'endPointLatLng', 'destination_coordinate', 'to_coordinate'],
    lat: ['end_lat', 'endLat', 'end_latitude', 'endLatitude', 'end_point_lat', 'endPointLat', 'finish_lat', 'destination_lat', 'to_lat'],
    lng: ['end_lng', 'endLng', 'end_lon', 'endLon', 'end_longitude', 'endLongitude', 'end_point_lng', 'endPointLng', 'finish_lng', 'destination_lng', 'to_lng'],
  };
  for (const key of names.object) {
    const point = coordinateFrom(fields(travel, [key]));
    if (point) return point;
  }
  const pair = coordinateFrom(fields(travel, names.pair));
  if (pair) return pair;
  return coordinateFrom({ lat: fields(travel, names.lat), lng: fields(travel, names.lng) });
}

function travelTrack(travel) {
  const raw = fields(travel, ['track', 'trajectory', 'points', 'path', 'route', 'locations']);
  if (Array.isArray(raw)) return raw.map(coordinateFrom).filter(Boolean);
  const trail = fields(travel, ['trail', 'Trail']);
  if (typeof trail !== 'string') return [];
  return trail.split(/[;|\n]+/).map((segment) => coordinateFrom(segment)).filter(Boolean);
}

function coordinateText(point) {
  return point ? `${point[0].toFixed(5)}, ${point[1].toFixed(5)}` : '--';
}

function formatDuration(value) {
  if (value === null || value === undefined || value === '') return '--';
  if (typeof value === 'string' && /[:时分秒]/.test(value)) return value;
  let seconds = numberValue(value);
  if (seconds === null) return textValue(value);
  if (seconds > 100000) seconds /= 1000;
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}小时${Math.floor((seconds % 3600) / 60)}分`;
  if (seconds >= 60) return `${Math.floor(seconds / 60)}分${Math.round(seconds % 60)}秒`;
  return `${Math.round(seconds)}秒`;
}

function formatDate(value, fallback = '--') {
  if (value === null || value === undefined || value === '' || typeof value === 'object') return fallback;
  const numeric = numberValue(value);
  const dateInput = numeric !== null && numeric > 0 && numeric < 1000000000000 ? numeric * 1000 : value;
  const date = new Date(dateInput);
  return Number.isNaN(date.getTime()) ? textValue(value, fallback) : new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(date);
}

function renderTabs() {
  const tabs = $('#vehicleTabs');
  tabs.replaceChildren(...state.vehicles.map((vehicle) => {
    const button = document.createElement('button');
    button.className = `segment${vehicleSN(vehicle) === vehicleSN(state.selected) ? ' active' : ''}`;
    button.textContent = vehicleName(vehicle);
    button.addEventListener('click', () => selectVehicle(vehicle));
    return button;
  }));
}

function travelRows(payload) {
  const rows = unwrapArray(payload, ['list', 'rows', 'travels', 'rides', 'records', 'items', 'travel_list', 'data.list', 'data.rows', 'data.records', 'data.items']);
  if (rows.length) return rows;
  const single = fields(payload, ['last_ride', 'lastRide']);
  return single && typeof single === 'object' ? [single] : [];
}

function travelId(travel) {
  return fields(travel, ['id', 'travel_id', 'travelId', 'record_id', 'recordId', 'trip_id', 'tripId', 'ride_id', 'rideId']);
}

async function enrichTravelRows(sn, payload) {
  const rows = travelRows(payload);
  const candidates = rows.map((row, index) => ({ row, index, id: travelId(row) })).filter((item) => item.id !== null && item.id !== undefined && item.id !== '');
  if (!candidates.length) return payload;
  const details = await Promise.all(candidates.map(async ({ row, index, id }) => {
    try {
      const detail = await api(`/vehicles/${sn}/travel/${encodeURIComponent(String(id))}`);
      const detailObject = detail && typeof detail === 'object' ? detail : {};
      return { index, value: { ...row, ...detailObject, detail: detailObject } };
    } catch (_) {
      return { index, value: row };
    }
  }));
  const merged = [...rows];
  details.forEach(({ index, value }) => { merged[index] = value; });
  if (Array.isArray(payload)) return merged;
  if (payload && typeof payload === 'object') return { ...payload, list: merged };
  return { list: merged };
}

function lastRide() {
  return travelRows(state.travels)[0] || fields(state.travels, ['last_ride', 'lastRide']) || {};
}

function chargingPower() {
  return numberValue(fields(state.battery, ['charging_power', 'chargingPower', 'charge_power', 'chargePower']))
    ?? numberValue(fields(state.status, ['charging_power', 'chargingPower', 'charge_power', 'chargePower']));
}

function isCharging() {
  const flag = booleanValue(fields(state.status, ['charging', 'is_charging', 'isCharging', 'charge_status', 'chargeStatus']))
    ?? booleanValue(fields(state.battery, ['charging', 'is_charging', 'isCharging']));
  return flag === true || (chargingPower() !== null && chargingPower() > 0);
}

function isRiding() {
  const speed = numberValue(fields(state.status, ['speed', 'vehicle_speed', 'vehicleSpeed', 'loc.speed', 'location.speed']));
  const flag = booleanValue(fields(state.status, ['riding', 'is_riding', 'isRiding', 'running', 'is_running', 'isRunning', 'moving']));
  return flag === true || (speed !== null && speed > 1);
}

function renderDashboard() {
  const vehicle = state.selected || {};
  const status = state.status || {};
  const battery = state.battery || {};
  const travels = state.travels || {};
  const rows = travelRows(travels);
  const recent = rows[0] || lastRide();
  const batteryPercent = fields(status, ['dump_energy', 'dumpEnergy', 'battery_percent', 'batteryPercent', 'remaining_power', 'remainingPower', 'battery_level', 'batteryLevel', 'soc', 'battery', 'power'], fields(battery, ['soc', 'battery', 'remaining_power', 'battery_percent', 'battery_level']));
  const range = fields(status, ['precise_estimate_mileage', 'preciseEstimateMileage', 'endurance', 'remaining_mileage', 'remainingMileage', 'remaining_range', 'remainingRange', 'range']);
  const totalMileage = fields(status, ['total_mileage', 'totalMileage']);
  const monthMileage = fields(travels, ['month_mileage', 'total_mileages', 'totalMileages']);
  const mileage = totalMileage ?? monthMileage ?? fields(status, ['mileage']);
  const monthRideCount = fields(travels, ['total_count', 'totalCount', 'count', 'ride_count', 'rideCount']);
  const lastSpeed = fields(recent, ['max_speed', 'maxSpeed', 'max_speed_kmh', 'maxSpeedKmh', 'top_speed', 'highest_speed', 'speed_max', 'speed_maximum', 'speed']);
  const voltage = fields(battery, ['bms_voltage', 'bmsVoltage', 'voltage', 'battery_voltage', 'batteryVoltage', 'battery_list.0.bms_volt', 'batteryList.0.bms_volt']);
  const temperature = fields(battery, ['batt_temp', 'battTemp', 'temperature', 'battery_temperature', 'batteryTemperature', 'battery_list.0.bat_temp', 'batteryList.0.bat_temp']);
  const cycles = fields(battery, ['bms_cycles', 'bmsCycles', 'cycles', 'cycle_count', 'cycleCount', 'battery_list.0.bms_cycle', 'batteryList.0.bms_cycle']);
  const location = statusCoordinate(status);
  const charging = isCharging();
  const riding = isRiding();
  const vehicleState = charging ? '正在充电' : riding ? '骑行中' : (Object.keys(status).length ? '已停稳' : '--');

  $('#vehicleName').textContent = vehicleName(vehicle);
  $('#vehicleModel').textContent = fields(vehicle, ['vehicle_name_en', 'vehicle_name', 'model'], 'NINEBOT');
  const batteryText = number(batteryPercent, '%');
  $('#updatedAt').textContent = `更新于 ${new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date())}`;
  $('#topbarDate').textContent = new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', weekday: 'short' }).format(new Date());
  $('#batteryValue').textContent = batteryText;
  $('#batteryRingValue').textContent = batteryText;
  $('#batteryCopyValue').textContent = batteryText;
  const batteryNumber = numberValue(batteryPercent);
  document.documentElement.style.setProperty('--battery-pct', `${Math.max(0, Math.min(100, batteryNumber ?? 0))}%`);
  $('#batteryBar').style.width = `${Math.max(0, Math.min(100, batteryNumber ?? 0))}%`;
  $('#rangeValue').textContent = number(range, ' km', 1);
  $('#mileageValue').textContent = number(mileage, ' km', 1);
  $('#mileageLabel').textContent = totalMileage == null && monthMileage != null ? '本月里程' : '总里程';
  $('#vehicleStateValue').textContent = vehicleState;
  $('#lastTripSpeedValue').textContent = number(lastSpeed, ' km/h', 1);
  $('#monthRideValue').textContent = monthRideCount !== null && monthRideCount !== undefined ? `${textValue(monthRideCount)} 次` : (rows.length ? `${rows.length} 次` : '--');
  $('#batteryTemperatureSummaryValue').textContent = number(temperature, ' °C', 1);
  $('#batteryVoltageValue').textContent = number(voltage, ' V', 1);
  $('#batteryTemperatureValue').textContent = number(temperature, ' °C', 1);
  $('#chargingPowerValue').textContent = number(chargingPower(), ' W', 1);
  $('#batteryCyclesValue').textContent = number(cycles, ' 次');
  $('#chargingStatus').textContent = charging ? '正在充电' : '未充电';
  $('#locationValue').textContent = location ? `中国地图 · ${coordinateText(location)}` : '中国地图 · 暂无定位';
  $('#rawData').textContent = JSON.stringify({ vehicle, status, battery, travels }, null, 2);

  const image = fields(vehicle, ['image_url', 'v6_light_img_url', 'img_url', 'img'], fields(status, ['image_url', 'v6_light_img_url', 'img_url', 'img']));
  const imageElement = $('#vehicleImage');
  imageElement.hidden = !image;
  $('#vehiclePlaceholder').hidden = Boolean(image);
  if (image) imageElement.src = image;

  renderTravelRows(rows);
}

function escapeHTML(value) {
  const div = document.createElement('div');
  div.textContent = value;
  return div.innerHTML;
}

function renderTravelRows(rows) {
  const travelList = $('#travelList');
  if (!rows.length) {
    travelList.innerHTML = '<div class="travel-empty">当前月份暂无骑行记录</div>';
    return;
  }
  travelList.replaceChildren(...rows.map((travel, index) => {
    const track = travelTrack(travel);
    const start = travelCoordinate(travel, 'start') || track[0] || null;
    const end = travelCoordinate(travel, 'end') || track[track.length - 1] || null;
    const startTime = fields(travel, ['start_time', 'startTime', 'start_at', 'startAt', 'begin_time', 'beginTime', 'create_time', 'createTime', 'date', 'timestamp']);
    const endTime = fields(travel, ['end_time', 'endTime', 'end_at', 'endAt', 'finish_time', 'finishTime', 'stop_time', 'stopTime', 'end_timestamp']);
    const distance = fields(travel, ['mileages', 'distance', 'mileage', 'ride_distance', 'rideDistance', 'distance_km', 'distanceKm']);
    const duration = fields(travel, ['duration', 'duration_seconds', 'durationSeconds', 'duration_ms', 'durationMs', 'ride_time', 'rideTime', 'elapsed_time', 'elapsedTime', 'time']);
    const maxSpeed = fields(travel, ['max_speed', 'maxSpeed', 'max_speed_kmh', 'maxSpeedKmh', 'top_speed', 'highest_speed', 'speed_max', 'speed_maximum', 'speed']);
    const energy = fields(travel, ['used_electricity', 'usedElectricity', 'energy', 'energy_wh', 'energyWh', 'electricity', 'ec']);
    const card = document.createElement('article');
    card.className = 'travel-card';
    const mapId = `travel-map-${index}`;
    card.innerHTML = `
      <div class="travel-card-head">
        <div><strong>${escapeHTML(formatDate(startTime, `骑行 ${index + 1}`))}</strong><span>${endTime ? `结束 ${escapeHTML(formatDate(endTime))}` : '最近骑行'}</span></div>
        <b>${escapeHTML(number(distance, ' km', 1))}</b>
      </div>
      <div class="travel-card-body">
        <div id="${mapId}" class="travel-map" aria-label="骑行起点和终点地图"></div>
        <div class="travel-facts">
          <div><span>起点</span><strong>${escapeHTML(coordinateText(start))}</strong></div>
          <div><span>终点</span><strong>${escapeHTML(coordinateText(end))}</strong></div>
          <div><span>最高速度</span><strong>${escapeHTML(number(maxSpeed, ' km/h', 1))}</strong></div>
          <div><span>骑行时间</span><strong>${escapeHTML(formatDuration(duration))}</strong></div>
          <div><span>用电量</span><strong>${escapeHTML(number(energy, ' Wh', 1))}</strong></div>
        </div>
      </div>`;
    return card;
  }));
}

function clearMaps() {
  for (const map of mapInstances) map.remove();
  mapInstances.clear();
}

function mapIcon(kind) {
  if (!window.L) return null;
  const content = kind === 'vehicle' ? '<span class="vehicle-map-pin">9+</span>' : `<span class="route-map-pin ${kind}"></span>`;
  return L.divIcon({ className: 'nineplus-map-icon', html: content, iconSize: [34, 34], iconAnchor: [17, 17] });
}

function createLeafletMap(element, points, track = [], vehicle = false) {
  if (!element) return;
  if (!points.length && !track.length) {
    element.innerHTML = '<div class="map-empty">暂无定位数据</div>';
    return;
  }
  if (!window.L) {
    element.innerHTML = '<div class="map-empty">地图组件加载失败，请检查浏览器网络</div>';
    return;
  }
  const map = L.map(element, { zoomControl: true, attributionControl: true, preferCanvas: true });
  mapInstances.add(map);
  const chinaLayer = L.tileLayer(CHINA_MAP_TILE_URL, {
    subdomains: ['1', '2', '3', '4'],
    maxZoom: 18,
    minZoom: 3,
    keepBuffer: 2,
    attribution: '&copy; 高德地图',
  }).addTo(map);
  let fallbackLoaded = false;
  chinaLayer.once('tileerror', () => {
    if (fallbackLoaded) return;
    fallbackLoaded = true;
    map.removeLayer(chinaLayer);
    L.tileLayer(FALLBACK_MAP_TILE_URL, {
      maxZoom: 19,
      attribution: '&copy; OpenStreetMap contributors',
    }).addTo(map);
  });
  const allPoints = [...track, ...points];
  if (track.length > 1) L.polyline(track, { color: '#0071e3', weight: 4, opacity: .8 }).addTo(map);
  points.forEach((point, index) => {
    const marker = L.marker(point, { icon: mapIcon(vehicle ? 'vehicle' : index === 0 ? 'start' : 'end') });
    marker.addTo(map).bindTooltip(vehicle ? '车辆当前位置' : index === 0 ? '骑行起点' : '骑行终点');
  });
  if (allPoints.length === 1) map.setView(allPoints[0], 15);
  else map.fitBounds(L.latLngBounds(allPoints), { padding: [24, 24], maxZoom: 16 });
  setTimeout(() => map.invalidateSize(), 0);
}

function renderMaps() {
  clearMaps();
  const vehiclePoint = statusCoordinate(state.status || {});
  createLeafletMap($('#vehicleMap'), vehiclePoint ? [vehiclePoint] : [], [], true);
  travelRows(state.travels).forEach((travel, index) => {
    const track = travelTrack(travel);
    const points = [travelCoordinate(travel, 'start') || track[0], travelCoordinate(travel, 'end') || track[track.length - 1]].filter(Boolean);
    createLeafletMap(document.querySelector(`#travel-map-${index}`), points, track);
  });
}

async function selectVehicle(vehicle, snapshot = null) {
  state.selected = vehicle;
  renderTabs();
  $('#dashboard').hidden = true;
  $('#loadingState').hidden = false;
  const sn = encodeURIComponent(vehicleSN(vehicle));
  const month = $('#monthPicker').value;
  try {
    let status;
    let battery;
    let travels;
    if (snapshot) {
      // The aggregate dashboard already contains the live values. Reusing it
      // prevents a second serialized round of ninecli processes on page load.
      status = snapshot.status ?? null;
      battery = snapshot.battery ?? null;
      travels = snapshot.travel ?? null;
    } else {
      [status, battery, travels] = await Promise.all([
        api(`/vehicles/${sn}/status`),
        api(`/vehicles/${sn}/battery`).catch(() => null),
        api(`/vehicles/${sn}/travel?month=${encodeURIComponent(month)}&page_size=20`).catch(() => null),
      ]);
    }
    state.status = status;
    state.battery = battery;
    state.travels = travels;
    renderDashboard();
    $('#dashboard').hidden = false;
    requestAnimationFrame(renderMaps);
    const initialTravels = travels;
    if (initialTravels) {
      enrichTravelRows(sn, initialTravels).then((enriched) => {
        if (state.selected !== vehicle || enriched === initialTravels) return;
        state.travels = enriched;
        renderDashboard();
        requestAnimationFrame(renderMaps);
      });
    } else if (snapshot) {
      // History can take substantially longer than status/battery. Render the
      // control screen first, then hydrate the trip cards without reviving the
      // full-page loading state.
      api(`/vehicles/${sn}/travel?month=${encodeURIComponent(month)}&page_size=20`)
        .then((loadedTravels) => {
          if (state.selected !== vehicle) return null;
          state.travels = loadedTravels;
          renderDashboard();
          requestAnimationFrame(renderMaps);
          return enrichTravelRows(sn, loadedTravels);
        })
        .then((enriched) => {
          if (!enriched || state.selected !== vehicle) return;
          state.travels = enriched;
          renderDashboard();
          requestAnimationFrame(renderMaps);
        })
        .catch(() => {});
    }
  } catch (error) {
    toast(error.message);
  } finally {
    $('#loadingState').hidden = true;
  }
}

async function loadVehicles() {
  $('#dashboard').hidden = true;
  $('#emptyState').hidden = true;
  $('#loadingState').hidden = false;
  try {
    // One dashboard request returns the vehicle list plus live status/battery.
    // Travel history is intentionally loaded only after the user opens it.
    const payload = await api('/dashboard?include_travel=0');
    const snapshots = unwrapArray(payload, ['vehicles']);
    state.vehicles = snapshots
      .map((snapshot) => snapshot?.vehicle)
      .filter((vehicle) => vehicle && vehicleSN(vehicle));
    if (!state.vehicles.length) {
      $('#emptyState').hidden = false;
      return;
    }
    const previousSN = vehicleSN(state.selected);
    const selected = state.vehicles.find((vehicle) => vehicleSN(vehicle) === previousSN) || state.vehicles[0];
    const selectedSnapshot = snapshots.find((snapshot) => vehicleSN(snapshot?.vehicle) === vehicleSN(selected)) || null;
    renderTabs();
    await selectVehicle(selected, selectedSnapshot);
  } catch (error) {
    if (error.status === 401) setAuthenticated(false);
    toast(error.message);
  } finally {
    $('#loadingState').hidden = true;
  }
}

const actionCopy = {
  bell: ['鸣笛', '车辆将立即鸣笛，请确认车辆周围环境安全。'],
  buck: ['打开座桶', '座桶将立即解锁，请确认车辆就在你身边。'],
  engine_start: ['启动车辆', '车辆将远程启动，请确认车辆处于安全位置。'],
  engine_stop: ['关闭车辆', '车辆将远程熄火，请确认车辆当前没有行驶。'],
};

async function runAction(action) {
  const sn = encodeURIComponent(vehicleSN(state.selected));
  const status = $('#controlStatus');
  document.querySelectorAll('.control-button').forEach((button) => { button.disabled = true; });
  status.textContent = '执行中';
  try {
    await api(`/vehicles/${sn}/control`, { method: 'POST', body: JSON.stringify({ action, confirm: true }) });
    status.textContent = '已完成';
    toast(`${actionCopy[action][0]}成功`);
    setTimeout(() => loadVehicles(), 800);
  } catch (error) {
    status.textContent = '操作失败';
    toast(error.message);
  } finally {
    document.querySelectorAll('.control-button').forEach((button) => { button.disabled = false; });
  }
}

$('#loginForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = $('#loginButton');
  setBusy(button, true, '正在登录…');
  try {
    const session = await api('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ username: $('#portalUsername').value.trim(), password: $('#portalPassword').value }),
    });
    $('#portalPassword').value = '';
    setAuthenticated(true);
    toast(session.cloud_ready ? 'NinePlus 登录成功，正在同步车辆' : 'NinePlus 登录成功，正在检查服务器云端状态');
    await loadVehicles();
  } catch (error) {
    toast(error.message);
  } finally {
    setBusy(button, false);
  }
});

$('#refreshButton').addEventListener('click', loadVehicles);
$('#logoutButton').addEventListener('click', async () => {
  try { await api('/auth/logout', { method: 'POST' }); } catch (_) { /* clear local view regardless */ }
  state.vehicles = [];
  state.selected = null;
  setAuthenticated(false);
});
$('#monthPicker').addEventListener('change', () => state.selected && selectVehicle(state.selected));
document.querySelectorAll('.control-button').forEach((button) => {
  button.addEventListener('click', () => {
    const action = button.dataset.action;
    state.pendingAction = action;
    $('#confirmTitle').textContent = actionCopy[action][0];
    $('#confirmMessage').textContent = actionCopy[action][1];
    $('#confirmDialog').showModal();
  });
});
$('#confirmDialog').addEventListener('close', () => {
  if ($('#confirmDialog').returnValue === 'confirm' && state.pendingAction) runAction(state.pendingAction);
  state.pendingAction = null;
});

const now = new Date();
$('#monthPicker').value = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
api('/auth/me').then((session) => {
  if (session) {
    // A NinePlus session is sufficient to enter the console. The official
    // cloud binding is server-side configuration and is never requested here.
    setAuthenticated(true);
    loadVehicles();
  } else {
    setAuthenticated(false);
    showPortalLogin();
  }
}).catch(() => {
  setAuthenticated(false);
  showPortalLogin();
});
