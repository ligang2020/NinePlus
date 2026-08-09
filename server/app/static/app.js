const $ = (selector) => document.querySelector(selector);

const state = {
  vehicles: [],
  selected: null,
  status: null,
  battery: null,
  travels: null,
  pendingAction: null,
};

const fields = (object, keys, fallback = null) => {
  if (!object) return fallback;
  for (const key of keys) {
    const value = key.split('.').reduce((current, part) => current?.[part], object);
    if (value !== undefined && value !== null && value !== '') return value;
  }
  return fallback;
};

const unwrapArray = (value, keys = []) => {
  if (Array.isArray(value)) return value;
  for (const key of keys) if (Array.isArray(value?.[key])) return value[key];
  return [];
};

async function api(path, options = {}) {
  const response = await fetch(path, {
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

function setBusy(button, busy, label) {
  button.disabled = busy;
  if (!button.dataset.label) button.dataset.label = button.textContent;
  button.textContent = busy ? label : button.dataset.label;
}

function vehicleSN(vehicle) {
  return String(fields(vehicle, ['wnumber', 'sn', 'serial_number'], ''));
}

function vehicleName(vehicle) {
  return fields(vehicle, ['device_name', 'deviceName', 'ble_name', 'name'], vehicleSN(vehicle) || '九号车辆');
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

function number(value, suffix = '', digits = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? `${parsed.toFixed(digits)}${suffix}` : '--';
}

function coordinateText(status) {
  const latitude = fields(status, ['lat', 'latitude', 'location.lat', 'position.lat']);
  const longitude = fields(status, ['lng', 'lon', 'longitude', 'location.lng', 'position.lng']);
  if (latitude == null || longitude == null) return '--';
  return `${Number(latitude).toFixed(4)}, ${Number(longitude).toFixed(4)}`;
}

function travelRows(payload) {
  return unwrapArray(payload, ['list', 'rows', 'travels', 'data']);
}

function renderDashboard() {
  const vehicle = state.selected || {};
  const status = state.status || {};
  const battery = state.battery || {};
  const batteryPercent = fields(status, ['remaining_power', 'battery', 'battery_percent', 'power'], fields(battery, ['soc', 'battery', 'remaining_power']));
  const range = fields(status, ['remaining_mileage', 'remaining_range', 'range']);
  const mileage = fields(status, ['total_mileage', 'mileage', 'totalMileage']);
  const speed = fields(status, ['speed', 'vehicle_speed']);
  const online = fields(status, ['online', 'is_online', 'status']);
  const image = fields(vehicle, ['v6_light_img_url', 'img_url', 'img'], fields(status, ['v6_light_img_url', 'img_url', 'img']));

  $('#vehicleName').textContent = vehicleName(vehicle);
  $('#vehicleModel').textContent = fields(vehicle, ['vehicle_name_en', 'vehicle_name', 'model'], 'NINEBOT');
  $('#updatedAt').textContent = `更新于 ${new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date())}`;
  $('#batteryValue').textContent = number(batteryPercent, '%');
  $('#rangeValue').textContent = number(range, ' km', 1);
  $('#mileageValue').textContent = number(mileage, ' km', 1);
  $('#speedValue').textContent = number(speed, ' km/h', 1);
  $('#onlineValue').textContent = online === true || online === 1 || String(online).toLowerCase() === 'online' ? '在线' : online === false || online === 0 ? '离线' : String(online ?? '--');
  $('#locationValue').textContent = coordinateText(status);
  $('#batteryHealthValue').textContent = number(fields(battery, ['soh', 'health', 'battery_health']), '%');
  $('#rawData').textContent = JSON.stringify({ vehicle, status, battery, travels: state.travels }, null, 2);

  const imageElement = $('#vehicleImage');
  imageElement.hidden = !image;
  $('#vehiclePlaceholder').hidden = Boolean(image);
  if (image) imageElement.src = image;

  const rows = travelRows(state.travels);
  const travelList = $('#travelList');
  if (!rows.length) {
    travelList.innerHTML = '<div class="travel-empty">当前月份暂无骑行记录</div>';
  } else {
    travelList.replaceChildren(...rows.map((travel, index) => {
      const row = document.createElement('article');
      row.className = 'travel-row';
      const started = fields(travel, ['start_time', 'startTime', 'begin_time', 'date'], `骑行 ${index + 1}`);
      const distance = fields(travel, ['distance', 'mileage', 'ride_distance']);
      const duration = fields(travel, ['duration', 'ride_time', 'time']);
      const maxSpeed = fields(travel, ['max_speed', 'maxSpeed']);
      row.innerHTML = `<strong>${escapeHTML(String(started))}</strong><span>${escapeHTML(number(distance, ' km', 1))}</span><span>${escapeHTML(String(duration ?? '--'))}</span><span>${escapeHTML(number(maxSpeed, ' km/h', 1))}</span>`;
      return row;
    }));
  }
}

function escapeHTML(value) {
  const div = document.createElement('div');
  div.textContent = value;
  return div.innerHTML;
}

async function selectVehicle(vehicle) {
  state.selected = vehicle;
  renderTabs();
  $('#dashboard').hidden = true;
  $('#loadingState').hidden = false;
  const sn = encodeURIComponent(vehicleSN(vehicle));
  const month = $('#monthPicker').value;
  try {
    const [status, battery, travels] = await Promise.all([
      api(`/vehicles/${sn}/status`),
      api(`/vehicles/${sn}/battery`).catch(() => null),
      api(`/vehicles/${sn}/travel?month=${encodeURIComponent(month)}&page_size=20`).catch(() => null),
    ]);
    state.status = status;
    state.battery = battery;
    state.travels = travels;
    renderDashboard();
    $('#dashboard').hidden = false;
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
    const payload = await api('/vehicles');
    state.vehicles = unwrapArray(payload, ['vehicles', 'data']);
    if (!state.vehicles.length) {
      $('#emptyState').hidden = false;
      return;
    }
    const previousSN = vehicleSN(state.selected);
    const selected = state.vehicles.find((vehicle) => vehicleSN(vehicle) === previousSN) || state.vehicles[0];
    renderTabs();
    await selectVehicle(selected);
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
    await api('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ account: $('#account').value.trim(), password: $('#password').value }),
    });
    $('#password').value = '';
    setAuthenticated(true);
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
api('/auth/me').then(() => { setAuthenticated(true); loadVehicles(); }).catch(() => setAuthenticated(false));
