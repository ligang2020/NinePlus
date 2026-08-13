from __future__ import annotations

import asyncio
import copy
import hmac
import json
import logging
import math
import os
import re
import secrets
import shutil
import sys
import time
from datetime import datetime
from zoneinfo import ZoneInfo
from pathlib import Path
from typing import Any, Literal

import httpx
import jwt

from fastapi import Cookie, FastAPI, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field


APP_DIR = Path(__file__).resolve().parent
SESSION_TTL = max(300, int(os.getenv("NINEPLUS_SESSION_TTL", "2592000")))
CLI_TIMEOUT = max(5, int(os.getenv("NINEPLUS_CLI_TIMEOUT", "45")))
# Read-only cloud data changes slowly compared with the cost of starting a
# ninecli process.  These TTLs are deliberately short so the app remains
# responsive without making vehicle controls or battery state stale for long.
CACHE_TTL_VEHICLES = max(0.0, float(os.getenv("NINEPLUS_CACHE_TTL_VEHICLES", "30")))
CACHE_TTL_STATUS = max(0.0, float(os.getenv("NINEPLUS_CACHE_TTL_STATUS", "8")))
CACHE_TTL_BATTERY = max(0.0, float(os.getenv("NINEPLUS_CACHE_TTL_BATTERY", "15")))
CACHE_TTL_TRAVEL = max(0.0, float(os.getenv("NINEPLUS_CACHE_TTL_TRAVEL", "60")))
COOKIE_SECURE = os.getenv("NINEPLUS_COOKIE_SECURE", "auto").lower()
BOOT_TIME = time.time()
SN_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
TRAVEL_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
MONTH_PATTERN = re.compile(r"^(?:\d{4}-?\d{2})$")
SESSION_ROOT = Path(os.getenv("NINEPLUS_SESSION_ROOT", "/run/nineplus/sessions"))
# Keep the official ninecli token/config on the persistent session volume.
# NinePlus credentials authenticate a user session; the official cloud binding
# belongs to the server installation and is reused by every device that logs
# into that NinePlus account.
PERSISTENT_CLOUD_DIR = SESSION_ROOT / "official"
PERSISTENT_CLOUD_META = SESSION_ROOT / "official-account.json"
TOTAL_MILEAGE_CACHE = SESSION_ROOT / "total-mileage.json"
PUSH_DEVICES_FILE = SESSION_ROOT / "push-devices.json"
PUSH_EVENT_STATE_FILE = SESSION_ROOT / "push-event-state.json"
PORTAL_SESSIONS_FILE = SESSION_ROOT / "portal-sessions.json"
PORTAL_USERNAME = os.getenv("NINEPLUS_PORTAL_USERNAME", "gang").strip()
PORTAL_PASSWORD = os.getenv("NINEPLUS_PORTAL_PASSWORD", "")
# Optional installation-wide app token. When configured, every API request
# (including APNs token registration) must include Authorization: Bearer <token>.
# Leave blank only for trusted LAN deployments that do not require this extra layer.
APP_BEARER_TOKEN = os.getenv("NINEPLUS_APP_BEARER_TOKEN", "").strip()
# APNs token-based provider credentials. Keep the .p8 file on the mounted
# session volume (or another server-only path), never in the repository.
APNS_KEY_ID = os.getenv("NINEPLUS_APNS_KEY_ID", "").strip()
APNS_TEAM_ID = os.getenv("NINEPLUS_APNS_TEAM_ID", "").strip()
APNS_AUTH_KEY_PATH = Path(os.getenv("NINEPLUS_APNS_AUTH_KEY_PATH", "").strip()).expanduser()
APNS_REQUEST_TIMEOUT = max(3.0, float(os.getenv("NINEPLUS_APNS_REQUEST_TIMEOUT", "10")))
NINECLI_BIN = os.getenv("NINEPLUS_NINECLI_BIN", "").strip()
NINECLI_MODULE = os.getenv("NINEPLUS_NINECLI_MODULE", "ninecli").strip() or "ninecli"
DEVICE_ID = os.getenv("NINEPLUS_DEVICE_ID", "").strip().lower() or secrets.token_hex(16)
if not re.fullmatch(r"[0-9a-f]{32}", DEVICE_ID):
    raise RuntimeError("NINEPLUS_DEVICE_ID must be a 32-character hexadecimal value")

logger = logging.getLogger("nineplus")
logging.basicConfig(level=os.getenv("NINEPLUS_LOG_LEVEL", "INFO"))

app = FastAPI(
    title="NinePlus",
    version="6.0.0",
    description=(
        "Unofficial personal Ninebot web console. The backend invokes the "
        "community ninecli command-line client against the user-facing cloud service."
    ),
    docs_url="/api/docs",
    redoc_url=None,
)
app.mount("/assets", StaticFiles(directory=APP_DIR / "static"), name="assets")


@app.middleware("http")
async def require_access_token(request: Request, call_next):
    # The portal session is still validated by each protected handler.  An
    # installation can additionally require a Bearer token for every API
    # request, which is important for APNs device-token registration from the
    # iOS app. Static assets and health checks remain reachable for deployment
    # probes; the app sends this header even for /auth/login.
    public_paths = {"/", "/healthz", "/openapi.json", "/api/docs"}
    if APP_BEARER_TOKEN and request.url.path not in public_paths and not request.url.path.startswith("/assets/"):
        authorization = request.headers.get("authorization", "")
        expected = f"Bearer {APP_BEARER_TOKEN}"
        if not hmac.compare_digest(authorization, expected):
            return JSONResponse(
                status_code=401,
                content={"ok": False, "error": {"code": "bearer_token_required", "message": "服务器已启用 Bearer Token，请在 App 登录前填写正确的 Token"}},
                headers={"Cache-Control": "no-store"},
            )
    return await call_next(request)



class PortalLoginBody(BaseModel):
    # NinePlus accounts are local to this installation.  The password is read
    # from NINEPLUS_PORTAL_PASSWORD and is never stored in the repository.
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=256)


class OfficialLoginBody(BaseModel):
    account: str = Field(min_length=3, max_length=128)
    password: str = Field(min_length=1, max_length=256)
    area_code: str | None = Field(default=None, max_length=8)


class ControlBody(BaseModel):
    action: Literal["bell", "buck", "engine_start", "engine_stop"]
    confirm: bool = False


class PushDeviceBody(BaseModel):
    # APNs device tokens are private credentials. Store them only on the
    # host-mounted session volume; never log or return the token.
    token: str = Field(min_length=1, max_length=4096)
    bundle_id: str = Field(min_length=1, max_length=256)
    environment: str = Field(min_length=1, max_length=32)


class CloudSession:
    def __init__(self, account: str, config_dir: Path, expires_at: float):
        self.account = account
        self.config_dir = config_dir
        self.expires_at = expires_at
        self.lock = asyncio.Lock()
        self.cache: dict[tuple[str, ...], tuple[float, Any]] = {}
        self.inflight: dict[tuple[str, ...], asyncio.Task[Any]] = {}


class PortalSession:
    def __init__(self, username: str, expires_at: float):
        self.username = username
        self.expires_at = expires_at
        self.cloud: CloudSession | None = None


sessions: dict[str, PortalSession] = {}
session_reaper_task: asyncio.Task[None] | None = None
push_devices_lock = asyncio.Lock()
push_event_state_lock = asyncio.Lock()
apns_jwt_lock = asyncio.Lock()
apns_jwt_cache: tuple[str, float] | None = None
# Rebinding the installation-wide ninecli account replaces shared credential
# files. Serialize that replacement with every cloud call so another device
# cannot observe a half-written config or keep using a removed directory.
official_binding_lock = asyncio.Lock()


def ok(data: Any = None) -> dict[str, Any]:
    return {"ok": True, "data": data if data is not None else {}}


def error(status: int, code: str, message: str, **extra: Any) -> None:
    detail: dict[str, Any] = {"code": code, "message": message}
    detail.update(extra)
    raise HTTPException(status_code=status, detail=detail)


def cookie_is_secure(request: Request) -> bool:
    if COOKIE_SECURE in {"1", "true", "yes", "on"}:
        return True
    if COOKIE_SECURE in {"0", "false", "no", "off"}:
        return False
    return request.url.scheme == "https"


def validate_sn(sn: str) -> str:
    if not SN_PATTERN.fullmatch(sn):
        error(400, "invalid_vehicle_sn", "车辆序列号格式无效")
    return sn


def validate_travel_id(travel_id: str) -> str:
    if not TRAVEL_ID_PATTERN.fullmatch(travel_id):
        error(400, "invalid_travel_id", "行程 ID 格式无效")
    return travel_id


def normalize_month(month: str) -> str:
    if not month:
        return ""
    if not MONTH_PATTERN.fullmatch(month):
        error(400, "invalid_month", "月份格式应为 YYYY-MM")
    normalized = month.replace("-", "")
    year, month_number = int(normalized[:4]), int(normalized[4:])
    if year < 2000 or year > 2100 or not 1 <= month_number <= 12:
        error(400, "invalid_month", "月份格式应为 YYYY-MM")
    return normalized


def cli_available() -> bool:
    if NINECLI_BIN:
        return bool(shutil.which(NINECLI_BIN) or Path(NINECLI_BIN).exists())
    try:
        import importlib.util

        return importlib.util.find_spec(NINECLI_MODULE) is not None
    except (ImportError, ModuleNotFoundError, ValueError):
        return False


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        number = float(str(value).strip().replace(",", "."))
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _coordinate_pair(value: Any) -> list[float] | None:
    """Normalize Ninebot coordinates to [latitude, longitude].

    Ninebot's official travel detail uses ``longitude,latitude,speed,...``
    while status uses an object with ``lat``/``lon``.  The API exposes a
    single unambiguous shape to web and iOS clients, while retaining the raw
    cloud response alongside it.
    """
    if isinstance(value, str):
        parts = [_number(part) for part in re.split(r"[,;|\s]+", value.strip()) if part]
        if len(parts) < 2 or parts[0] is None or parts[1] is None:
            return None
        first, second = parts[0], parts[1]
    elif isinstance(value, (list, tuple)) and len(value) >= 2:
        first, second = _number(value[0]), _number(value[1])
        if first is None or second is None:
            return None
    elif isinstance(value, dict):
        lat = next((_number(value.get(key)) for key in ("lat", "latitude", "gcj02_lat", "gcj02Lat", "y") if value.get(key) is not None), None)
        lon = next((_number(value.get(key)) for key in ("lon", "lng", "longitude", "gcj02_lon", "gcj02Lng", "gcj02_lng", "x") if value.get(key) is not None), None)
        if lat is None or lon is None:
            return None
        first, second = lat, lon
    else:
        return None

    if abs(first) > 90 and abs(second) <= 90:
        latitude, longitude = second, first
    else:
        latitude, longitude = first, second
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    return [latitude, longitude]


def wgs84_to_gcj02(latitude: float, longitude: float) -> list[float]:
    """Convert official Ninebot WGS-84 GPS coordinates for AMap tiles.

    Ninebot status/travel payloads use WGS-84.  高德地图 (the web map's
    primary tile source) is GCJ-02, so plotting raw values visibly shifts a
    marker by several hundred metres in mainland China.
    """
    if not (72.004 < longitude < 137.8347 and 0.8293 < latitude < 55.8271):
        return [latitude, longitude]
    x = longitude - 105.0
    y = latitude - 35.0
    latitude_delta = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    latitude_delta += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    latitude_delta += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    latitude_delta += (160.0 * math.sin(y / 12.0 * math.pi) + 320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    longitude_delta = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    longitude_delta += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    longitude_delta += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    longitude_delta += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    eccentricity = 0.00669342162296594323
    radians = latitude / 180.0 * math.pi
    magic = 1.0 - eccentricity * math.sin(radians) ** 2
    sqrt_magic = math.sqrt(magic)
    latitude_delta = (latitude_delta * 180.0) / ((6378245.0 * (1.0 - eccentricity)) / (magic * sqrt_magic) * math.pi)
    longitude_delta = (longitude_delta * 180.0) / (6378245.0 / sqrt_magic * math.cos(radians) * math.pi)
    return [latitude + latitude_delta, longitude + longitude_delta]


def _track_from_trail(value: Any) -> list[dict[str, float]]:
    """Preserve official per-point speed while normalizing coordinates.

    Official trail records normally use ``longitude,latitude,speed,distance``.
    Earlier builds discarded every field after the coordinates, which made the
    iOS route map unable to colour the line by interface-provided speed.
    """
    if not isinstance(value, str):
        return []
    points: list[dict[str, float]] = []
    for segment in re.split(r"[;|\n]+", value):
        numbers = [_number(part) for part in re.split(r"[,\s]+", segment.strip()) if part]
        if len(numbers) < 2 or numbers[0] is None or numbers[1] is None:
            continue
        coordinate = _coordinate_pair([numbers[0], numbers[1]])
        if coordinate is None:
            continue
        latitude, longitude = coordinate
        point: dict[str, float] = {"latitude": latitude, "longitude": longitude}
        if len(numbers) >= 3 and numbers[2] is not None and 0 <= numbers[2] <= 160:
            point["speed_kmh"] = numbers[2]
        if len(numbers) >= 4 and numbers[3] is not None and numbers[3] >= 0:
            point["distance_meters"] = numbers[3]
        if not points or (latitude, longitude) != (points[-1]["latitude"], points[-1]["longitude"]):
            points.append(point)
    return points


def _find_trail(value: Any) -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() == "trail" and isinstance(child, str) and child.strip():
                return child
            found = _find_trail(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_trail(child)
            if found:
                return found
    return None


def normalize_travel_detail(payload: Any) -> Any:
    """Add stable route fields without altering the upstream response."""
    if not isinstance(payload, dict):
        return payload
    detail = copy.deepcopy(payload)
    trail = _find_trail(detail)
    track = _track_from_trail(trail) if trail else []
    if len(track) >= 2:
        map_track: list[dict[str, float]] = []
        for point in track:
            latitude, longitude = wgs84_to_gcj02(point["latitude"], point["longitude"])
            normalized = {**point, "latitude": latitude, "longitude": longitude}
            map_track.append(normalized)
        detail["track"] = map_track
        detail["start_coordinate"] = [map_track[0]["latitude"], map_track[0]["longitude"]]
        detail["end_coordinate"] = [map_track[-1]["latitude"], map_track[-1]["longitude"]]
        detail["coordinate_system"] = "gcj02"
        detail["source_coordinate_system"] = "wgs84"
        detail["track_point_count"] = len(track)
        detail["track_speed_source"] = "ninebot_interface"
    return detail


def normalize_status_location(payload: Any) -> Any:
    if not isinstance(payload, dict):
        return payload
    location = payload.get("loc") or payload.get("location") or payload.get("position")
    coordinate = _coordinate_pair(location)
    if not coordinate:
        coordinate = _coordinate_pair({"lat": payload.get("lat"), "lon": payload.get("lon")})
    if not coordinate:
        return payload
    result = copy.deepcopy(payload)
    map_coordinate = wgs84_to_gcj02(coordinate[0], coordinate[1])
    result["location_coordinate"] = map_coordinate
    result["location_coordinate_system"] = "gcj02"
    result["source_coordinate_system"] = "wgs84"
    # Keep both coordinate spaces explicit for native clients: the web map
    # consumes the GCJ-02 pair, while weather/geofencing can still use the
    # original WGS-84 fix without a lossy reverse conversion.
    result["source_latitude"] = coordinate[0]
    result["source_longitude"] = coordinate[1]
    result["latitude"] = map_coordinate[0]
    result["longitude"] = map_coordinate[1]
    return result


def parse_cli_json(stdout: bytes) -> Any:
    text = stdout.decode("utf-8", errors="replace").strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Some ninecli builds add a short informational line before JSON. Find
        # the first valid JSON document without exposing the raw output to users.
        decoder = json.JSONDecoder()
        for index, char in enumerate(text):
            if char not in "[{":
                continue
            try:
                value, _ = decoder.raw_decode(text[index:])
                return value
            except json.JSONDecodeError:
                continue
    return {"raw": text}


def normalize_area_code(value: str | None) -> str:
    area_code = (value or "86").strip().lstrip("+")
    if not area_code.isdigit() or len(area_code) > 8:
        error(422, "invalid_area_code", "国家/地区区号格式无效")
    return area_code


def prepare_cli_config(config_dir: Path, area_code: str = "86") -> None:
    """Create the client config before login so ninecli does not use its placeholder ID."""
    config_path = config_dir / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "device_id": DEVICE_ID,
                "region": "bj",
                "area_code": area_code,
                "os_version": "17",
                "os_model": "iPhone",
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    config_path.chmod(0o600)


def is_persistent_cloud(session: CloudSession | None) -> bool:
    return session is not None and session.config_dir.resolve() == PERSISTENT_CLOUD_DIR.resolve()


def cleanup_session(session: CloudSession | None) -> None:
    if session is not None and not is_persistent_cloud(session):
        shutil.rmtree(session.config_dir, ignore_errors=True)


def restore_persistent_cloud() -> CloudSession | None:
    """Return the installation-wide official cloud session.

    The binding is deliberately independent from a browser or phone session.
    This is what makes a second device work after it logs into NinePlus: it
    receives a new portal session, then reuses the same persisted ninecli
    credentials instead of asking for the official account again.

    NAS bind mounts can contain files created by an older root container. Treat
    unreadable legacy state as unavailable instead of turning a valid portal
    login into an unhandled 500 response.
    """
    # Reuse the in-memory object when another device/session already attached
    # the shared config. Besides avoiding duplicate locks, this also preserves
    # its short-lived response cache across device logins.
    for existing in sessions.values():
        cloud = existing.cloud
        if is_persistent_cloud(cloud):
            cloud.expires_at = max(cloud.expires_at, time.time() + SESSION_TTL)
            return cloud

    try:
        if not PERSISTENT_CLOUD_DIR.is_dir() or not (PERSISTENT_CLOUD_DIR / "config.json").is_file():
            return None
        metadata = json.loads(PERSISTENT_CLOUD_META.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        logger.warning("persistent official account binding is unavailable: %s", exc)
        return None
    account = str(metadata.get("account") or "").strip() if isinstance(metadata, dict) else ""
    if not account:
        logger.warning("persistent official config found without account metadata; ignoring it")
        return None
    logger.info("restored persistent official account binding for %s", account)
    return CloudSession(account, PERSISTENT_CLOUD_DIR, time.time() + SESSION_TTL)


def attach_persistent_cloud(portal: PortalSession) -> CloudSession | None:
    """Attach the server-wide cloud binding to a freshly authenticated user."""
    if portal.cloud is None:
        portal.cloud = restore_persistent_cloud()
    if portal.cloud is not None:
        portal.cloud.expires_at = portal.expires_at
    return portal.cloud


def persist_official_account(account: str) -> None:
    """Atomically persist the server-wide official account metadata."""
    SESSION_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = SESSION_ROOT / f".official-account-{secrets.token_hex(8)}.tmp"
    temporary.write_text(
        json.dumps({"account": account}, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        temporary.chmod(0o600)
        os.replace(temporary, PERSISTENT_CLOUD_META)
        try:
            PERSISTENT_CLOUD_META.chmod(0o600)
        except OSError:
            pass
    finally:
        temporary.unlink(missing_ok=True)


def replace_persistent_cloud(temp_dir: Path, account: str) -> None:
    """Install a verified temporary cloud config without destroying the old one.

    The temporary directory is created beside the persistent directory, so the
    renames are normally same-filesystem operations. Keeping a backup until
    metadata is committed also protects an existing binding if a bind mount or
    permission boundary rejects the replacement midway through.
    """
    backup_dir = SESSION_ROOT / f".official-backup-{secrets.token_hex(8)}"
    had_old_dir = PERSISTENT_CLOUD_DIR.exists()
    if had_old_dir:
        PERSISTENT_CLOUD_DIR.rename(backup_dir)
    try:
        temp_dir.rename(PERSISTENT_CLOUD_DIR)
        try:
            persist_official_account(account)
        except Exception:
            shutil.rmtree(PERSISTENT_CLOUD_DIR, ignore_errors=True)
            if backup_dir.exists():
                backup_dir.rename(PERSISTENT_CLOUD_DIR)
            raise
    except Exception:
        if backup_dir.exists() and not PERSISTENT_CLOUD_DIR.exists():
            backup_dir.rename(PERSISTENT_CLOUD_DIR)
        raise
    finally:
        if backup_dir.exists():
            shutil.rmtree(backup_dir, ignore_errors=True)


def cleanup_portal_session(session: PortalSession) -> None:
    cleanup_session(session.cloud)
    session.cloud = None


def _session_payload() -> dict[str, Any]:
    records: dict[str, Any] = {}
    for token, session in sessions.items():
        cloud = session.cloud
        records[token] = {
            "username": session.username,
            "expires_at": session.expires_at,
            # The remote deployment uses one installation-wide official
            # ninecli binding. Do not duplicate or log its credential files.
            "official_account_bound": cloud is not None,
        }
    return {"version": 1, "sessions": records}


def persist_portal_sessions() -> None:
    """Persist portal tokens without storing either account password.

    A legacy NAS deployment may leave root-owned state files in the bind mount.
    Persistence is best-effort: a permission problem must never turn a valid
    login into an HTTP 500 because the active session is already in memory.
    """
    try:
        SESSION_ROOT.mkdir(parents=True, exist_ok=True)
        try:
            SESSION_ROOT.chmod(0o700)
        except OSError as exc:
            logger.warning("could not chmod session root %s: %s", SESSION_ROOT, exc)
        temporary = PORTAL_SESSIONS_FILE.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(_session_payload(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        try:
            temporary.chmod(0o600)
        except OSError as exc:
            logger.warning("could not chmod temporary session file: %s", exc)
        os.replace(temporary, PORTAL_SESSIONS_FILE)
        try:
            PORTAL_SESSIONS_FILE.chmod(0o600)
        except OSError as exc:
            logger.warning("could not chmod session file: %s", exc)
    except OSError as exc:
        logger.warning("could not persist NinePlus sessions; keeping session in memory: %s", exc)


def restore_portal_sessions() -> None:
    """Restore valid portal sessions after a container/process restart."""
    try:
        payload = json.loads(PORTAL_SESSIONS_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, ValueError, TypeError):
        return
    records = payload.get("sessions") if isinstance(payload, dict) else None
    if not isinstance(records, dict):
        return

    now = time.time()
    restored = 0
    shared_cloud: CloudSession | None = None
    for token, record in records.items():
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{20,256}", token):
            continue
        if not isinstance(record, dict):
            continue
        username = record.get("username")
        expires_at = record.get("expires_at")
        if (not isinstance(username, str) or not username
                or not isinstance(expires_at, (int, float))
                or float(expires_at) <= now):
            continue

        portal = PortalSession(username, float(expires_at))
        if record.get("official_account_bound"):
            if shared_cloud is None:
                shared_cloud = restore_persistent_cloud()
            if shared_cloud is not None:
                shared_cloud.expires_at = max(shared_cloud.expires_at, portal.expires_at)
                portal.cloud = shared_cloud
        sessions[token] = portal
        restored += 1

    if restored != len(records):
        persist_portal_sessions()
    if restored:
        logger.info("restored %d persisted NinePlus session(s)", restored)


def reap_expired_sessions() -> None:
    now = time.time()
    changed = False
    for token, session in list(sessions.items()):
        if session.expires_at <= now:
            sessions.pop(token, None)
            cleanup_portal_session(session)
            changed = True
    if changed:
        persist_portal_sessions()


async def session_reaper() -> None:
    try:
        while True:
            await asyncio.sleep(min(60, max(5, SESSION_TTL // 4)))
            reap_expired_sessions()
    except asyncio.CancelledError:
        raise


def _load_push_devices() -> list[dict[str, Any]]:
    try:
        payload = json.loads(PUSH_DEVICES_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, ValueError, TypeError):
        return []
    if isinstance(payload, dict) and isinstance(payload.get("devices"), list):
        return [item for item in payload["devices"] if isinstance(item, dict)]
    return []


async def _save_push_device(
    *,
    owner: str,
    official_account: str | None,
    token: str,
    bundle_id: str,
    environment: str,
) -> None:
    # APNs tokens are device-specific. Keep every current phone registration
    # for this portal user and replace a registration only when that token
    # itself rotates.
    async with push_devices_lock:
        PUSH_DEVICES_FILE.parent.mkdir(parents=True, exist_ok=True)
        devices = _load_push_devices()
        # APNs tokens rotate, so replace only the exact token. Do not evict
        # another phone owned by the same user: each registered device should
        # receive the vehicle event.
        retained = [item for item in devices if item.get("token") != token]
        retained.append({
            "owner": owner,
            "official_account": official_account,
            "token": token,
            "bundle_id": bundle_id,
            "environment": environment,
            "updated_at": int(time.time()),
        })
        temporary = PUSH_DEVICES_FILE.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps({"devices": retained}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        os.replace(temporary, PUSH_DEVICES_FILE)
        try:
            PUSH_DEVICES_FILE.chmod(0o600)
        except OSError:
            pass


def apns_configured() -> bool:
    return bool(APNS_KEY_ID and APNS_TEAM_ID and APNS_AUTH_KEY_PATH.is_file())


def _push_state_payload() -> dict[str, Any]:
    """Load per-NinePlus-user vehicle state used for transition detection.

    State files written by pre-v5 builds used a top-level ``vehicles`` mapping.
    It has no reliable owner association, so it is deliberately not reused for a
    user after migration: the next dashboard sample becomes that user's clean
    baseline instead of suppressing, or incorrectly creating, an event.
    """
    try:
        payload = json.loads(PUSH_EVENT_STATE_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, ValueError, TypeError):
        return {"owners": {}}
    if not isinstance(payload, dict):
        return {"owners": {}}
    owners = payload.get("owners")
    if not isinstance(owners, dict):
        return {"owners": {}}
    normalized_owners = {
        str(owner): state
        for owner, state in owners.items()
        if isinstance(state, dict) and isinstance(state.get("vehicles"), dict)
    }
    return {"owners": normalized_owners}


def _store_push_state(payload: dict[str, Any]) -> None:
    PUSH_EVENT_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = PUSH_EVENT_STATE_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, PUSH_EVENT_STATE_FILE)
    try:
        PUSH_EVENT_STATE_FILE.chmod(0o600)
    except OSError:
        pass


def _nested_values(value: Any):
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key), child
            yield from _nested_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from _nested_values(child)


def _bool_like(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on", "charging", "riding", "moving"}:
            return True
        if normalized in {"0", "false", "no", "off", "idle", "stopped", "none", "null", ""}:
            return False
    return None


def _first_named_bool(payloads: list[Any], keys: set[str]) -> bool | None:
    normalized_keys = {key.lower() for key in keys}
    for payload in payloads:
        for key, value in _nested_values(payload):
            if key.lower() not in normalized_keys:
                continue
            parsed = _bool_like(value)
            if parsed is not None:
                return parsed
    return None


def _first_named_number(payloads: list[Any], keys: set[str]) -> float | None:
    normalized_keys = {key.lower() for key in keys}
    for payload in payloads:
        for key, value in _nested_values(payload):
            if key.lower() not in normalized_keys:
                continue
            number = _number(value)
            if number is not None:
                return number
    return None


def _alarm_summary(payloads: list[Any]) -> str | None:
    for payload in payloads:
        for key, value in _nested_values(payload):
            normalized_key = key.lower()
            if not any(marker in normalized_key for marker in ("alarm", "fault", "error")):
                continue
            if isinstance(value, (dict, list)):
                continue
            if isinstance(value, str):
                detail = value.strip()
                if detail and detail.lower() not in {"0", "false", "no", "off", "none", "null", "normal", "ok"}:
                    return f"{key}：{detail}"
            elif isinstance(value, bool):
                if value:
                    return key
            else:
                number = _number(value)
                if number not in (None, 0):
                    return f"{key}：{number:g}"
    return None


def vehicle_notification_state(status: Any, battery: Any) -> dict[str, Any]:
    payloads = [status, battery]
    charging = _first_named_bool(
        payloads,
        {"charging", "charging_state", "chargingstate", "is_charging", "ischarging"},
    )
    riding = _first_named_bool(
        payloads,
        {"is_riding", "isriding", "riding", "is_moving", "ismoving", "moving", "in_motion", "inmotion", "driving"},
    )
    if riding is None:
        speed = _first_named_number(
            payloads,
            {"speed", "current_speed", "currentspeed", "speed_kmh", "speedkmh", "vehicle_speed", "vehiclespeed"},
        )
        if speed is not None and 0 <= speed <= 160:
            riding = speed >= 3
    return {
        "charging": charging,
        "riding": riding,
        "alarm": _alarm_summary(payloads),
    }


def _vehicle_name(vehicle: dict[str, Any], sn: str) -> str:
    for key in ("device_name", "deviceName", "name", "vehicle_name", "vehicleName", "model"):
        value = vehicle.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return sn


def _vehicle_location(status: Any) -> tuple[float | None, float | None]:
    if not isinstance(status, dict):
        return None, None
    coordinate = _coordinate_pair(status.get("loc") or status.get("location") or status.get("position"))
    if coordinate is None:
        coordinate = _coordinate_pair({"lat": status.get("source_latitude") or status.get("lat"), "lon": status.get("source_longitude") or status.get("lon")})
    if coordinate is None:
        return None, None
    return coordinate[0], coordinate[1]


def _notification_event(
    *,
    event_type: str,
    vehicle_name: str,
    sn: str,
    occurred_at: float,
    latitude: float | None,
    longitude: float | None,
    detail: str | None = None,
) -> dict[str, Any]:
    labels = {
        "charge_started": ("开始充电", "车辆开始充电"),
        "charge_ended": ("充电结束", "车辆已结束充电"),
        "ride_started": ("开始骑行", "车辆开始骑行"),
        "ride_ended": ("骑行结束", "车辆已结束骑行"),
        "alarm": ("车辆报警", detail or "车辆接口返回报警"),
    }
    title, summary = labels[event_type]
    timestamp = datetime.fromtimestamp(occurred_at, ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d %H:%M")
    return {
        "event_type": event_type,
        "title": title,
        "body": f"{vehicle_name}（{sn}）{summary}\n{timestamp}",
        "vehicle_name": vehicle_name,
        "vehicle_sn": sn,
        "occurred_at": occurred_at,
        "latitude": latitude,
        "longitude": longitude,
        "detail": detail,
    }


async def _apns_provider_token() -> str:
    global apns_jwt_cache
    if not apns_configured():
        raise RuntimeError("APNs provider credentials are not configured")
    now = time.time()
    async with apns_jwt_lock:
        if apns_jwt_cache is not None and apns_jwt_cache[1] > now:
            return apns_jwt_cache[0]
        private_key = APNS_AUTH_KEY_PATH.read_text(encoding="utf-8")
        token = jwt.encode(
            {"iss": APNS_TEAM_ID, "iat": int(now)},
            private_key,
            algorithm="ES256",
            headers={"kid": APNS_KEY_ID},
        )
        if isinstance(token, bytes):
            token = token.decode("utf-8")
        apns_jwt_cache = (token, now + 50 * 60)
        return token


def _apns_host(environment: str) -> str:
    return "https://api.sandbox.push.apple.com" if environment in {"development", "sandbox"} else "https://api.push.apple.com"


async def _send_apns(device: dict[str, Any], event: dict[str, Any]) -> bool:
    token = str(device.get("token") or "").strip()
    bundle_id = str(device.get("bundle_id") or "").strip()
    environment = str(device.get("environment") or "").strip().lower()
    if not token or not bundle_id or environment not in {"development", "sandbox", "production"}:
        return False

    try:
        provider_token = await _apns_provider_token()
    except (OSError, jwt.PyJWTError) as exc:
        logger.warning("APNs provider token creation failed: %s", type(exc).__name__)
        return False

    payload: dict[str, Any] = {
        "aps": {
            "alert": {"title": event["title"], "body": event["body"]},
            "sound": "default",
            "thread-id": event["vehicle_sn"],
        },
        "event_type": event["event_type"],
        "vehicle_name": event["vehicle_name"],
        "vehicle_sn": event["vehicle_sn"],
        "occurred_at": event["occurred_at"],
    }
    if event["latitude"] is not None and event["longitude"] is not None:
        payload["latitude"] = event["latitude"]
        payload["longitude"] = event["longitude"]
    if event["detail"]:
        payload["detail"] = event["detail"]

    headers = {
        "authorization": f"bearer {provider_token}",
        "apns-topic": bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "10",
    }
    try:
        async with httpx.AsyncClient(http2=True, timeout=APNS_REQUEST_TIMEOUT) as client:
            response = await client.post(f"{_apns_host(environment)}/3/device/{token}", headers=headers, json=payload)
    except httpx.HTTPError as exc:
        logger.warning("APNs delivery failed for bundle_id=%s: %s", bundle_id, type(exc).__name__)
        return False

    if 200 <= response.status_code < 300:
        return True
    reason = "unknown"
    try:
        reason = str(response.json().get("reason") or reason)
    except (ValueError, AttributeError):
        pass
    logger.warning("APNs rejected notification bundle_id=%s status=%s reason=%s", bundle_id, response.status_code, reason)
    return False


async def publish_vehicle_notifications(owner: str, vehicles: list[dict[str, Any]]) -> None:
    """Detect cloud state transitions and deliver APNs notifications.

    The first successful dashboard sample only establishes a baseline. Later
    samples emit charge/ride transitions and new server alarm values. An
    unlocked lock state is deliberately not inspected or sent as an alarm.
    """
    if not vehicles:
        return
    async with push_event_state_lock:
        saved = _push_state_payload()
        owners = saved.setdefault("owners", {})
        owner_state = owners.setdefault(owner, {"vehicles": {}})
        if not isinstance(owner_state, dict):
            owner_state = {"vehicles": {}}
            owners[owner] = owner_state
        known = owner_state.setdefault("vehicles", {})
        if not isinstance(known, dict):
            known = {}
            owner_state["vehicles"] = known
        events: list[dict[str, Any]] = []
        now = time.time()
        for item in vehicles:
            sn = item["sn"]
            state = vehicle_notification_state(item["status"], item["battery"])
            prior = known.get(sn)
            known[sn] = {**state, "updated_at": int(now)}
            if not isinstance(prior, dict):
                continue
            vehicle_name = item["vehicle_name"]
            latitude, longitude = _vehicle_location(item["status"])
            if prior.get("charging") is False and state["charging"] is True:
                events.append(_notification_event(event_type="charge_started", vehicle_name=vehicle_name, sn=sn, occurred_at=now, latitude=latitude, longitude=longitude))
            elif prior.get("charging") is True and state["charging"] is False:
                events.append(_notification_event(event_type="charge_ended", vehicle_name=vehicle_name, sn=sn, occurred_at=now, latitude=latitude, longitude=longitude))
            if prior.get("riding") is False and state["riding"] is True:
                events.append(_notification_event(event_type="ride_started", vehicle_name=vehicle_name, sn=sn, occurred_at=now, latitude=latitude, longitude=longitude))
            elif prior.get("riding") is True and state["riding"] is False:
                events.append(_notification_event(event_type="ride_ended", vehicle_name=vehicle_name, sn=sn, occurred_at=now, latitude=latitude, longitude=longitude))
            alarm = state.get("alarm")
            if alarm and alarm != prior.get("alarm"):
                events.append(_notification_event(event_type="alarm", vehicle_name=vehicle_name, sn=sn, occurred_at=now, latitude=latitude, longitude=longitude, detail=str(alarm)))
        _store_push_state(saved)

    if not events:
        return
    if not apns_configured():
        logger.info("vehicle notification state changed but APNs provider credentials are not configured")
        return
    devices = [device for device in _load_push_devices() if device.get("owner") == owner]
    if not devices:
        return
    deliveries = [_send_apns(device, event) for event in events for device in devices]
    results = await asyncio.gather(*deliveries, return_exceptions=True)
    delivered = sum(result is True for result in results)
    logger.info("published %d vehicle notification(s) to %d APNs target(s)", len(events), delivered)


def get_session(
    authorization: str | None,
    x_session: str | None,
    cookie_session: str | None,
) -> tuple[str, PortalSession]:
    # The app sends the session returned by POST /auth/login. Keep the
    # Authorization argument for source compatibility with older clients, but
    # never interpret it as an installation-wide access token.
    del authorization
    token = x_session or cookie_session
    if not token or token not in sessions:
        error(401, "not_authenticated", "请先登录 NinePlus 账号")
    session = sessions[token]

    now = time.time()
    if session.expires_at <= now:
        sessions.pop(token, None)
        cleanup_portal_session(session)
        persist_portal_sessions()
        error(401, "session_expired", "NinePlus 登录会话已过期，请重新登录 NinePlus 账号")

    # Sliding renewal keeps an actively used app session alive indefinitely
    # while abandoned sessions still expire after the configured TTL.
    if session.expires_at - now <= SESSION_TTL / 2:
        session.expires_at = now + SESSION_TTL
        if session.cloud is not None:
            session.cloud.expires_at = session.expires_at
        persist_portal_sessions()
    return token, session


def portal_from_request(request: Request, cookie: str | None) -> tuple[str, PortalSession]:
    return get_session(
        request.headers.get("authorization"),
        request.headers.get("x-nineplus-session"),
        cookie,
    )


async def auth_from_request(request: Request, cookie: str | None) -> tuple[str, CloudSession]:
    token, portal = portal_from_request(request, cookie)
    # The persistent config can be replaced by the administrator while a new
    # device is logging in. Resolve the shared object under the same lock used
    # by cloud calls and rebinding.
    async with official_binding_lock:
        cloud = attach_persistent_cloud(portal)
        if cloud is None:
            error(409, "cloud_account_not_configured", "NinePlus 已登录，但服务器尚未完成九号云端绑定")
        persist_portal_sessions()
        return token, cloud


async def run_cli(
    session: CloudSession,
    *args: str,
    password: str | None = None,
) -> Any:
    """Run ninecli using the same argument order as the official integration.

    The upstream Home Assistant integration invokes ``python -m ninecli`` and
    places ``--json`` after the subcommand arguments.  Keeping that shape is
    important because ninecli parses global and subcommand options separately.
    """
    if NINECLI_BIN:
        command = [NINECLI_BIN, "--config", str(session.config_dir), *args]
    else:
        command = [
            sys.executable,
            "-m",
            NINECLI_MODULE,
            "--config",
            str(session.config_dir),
            *args,
        ]
    if password is not None:
        command.extend(["-p", password])
    if "--json" not in command:
        command.append("--json")
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=CLI_TIMEOUT)
    except asyncio.TimeoutError:
        if "process" in locals():
            process.kill()
            await process.wait()
        error(504, "ninebot_cloud_timeout", "九号云请求超时，请稍后重试")
    except OSError:
        error(503, "ninecli_unavailable", "ninecli 未安装或不可执行")

    if process.returncode != 0:
        diagnostic = stderr.decode("utf-8", errors="replace").strip().replace("\n", " ")
        diagnostic_lower = diagnostic.lower()
        logger.warning("ninecli operation failed (%s): %s", args[0] if args else "unknown", diagnostic[:240])
        if args and args[0] == "login":
            if "resultcode=90014" in diagnostic_lower or "username or password incorrect" in diagnostic_lower:
                error(401, "login_failed", "九号云返回 90014：账号或密码不正确。请由服务器管理员确认九号官方 App 能使用同一账号登录")
            if any(marker in diagnostic_lower for marker in ("timeout", "deadline exceeded", "timed out", "i/o timeout")):
                error(504, "ninebot_cloud_timeout", "服务器连接九号云超时，请检查服务器网络后重试")
            error(502, "ninebot_cloud_error", "服务器绑定九号云失败，请查看后端日志")
        error(502, "ninebot_cloud_error", "九号云请求失败，请稍后重试")
    return parse_cli_json(stdout)


async def _run_cloud_call(session: CloudSession, args: tuple[str, ...]) -> Any:
    async with official_binding_lock:
        async with session.lock:
            return await run_cli(session, *args)


def invalidate_session_cache(session: CloudSession) -> None:
    session.cache.clear()


async def cloud_call(
    session: CloudSession,
    *args: str,
    cache_ttl: float = 0.0,
) -> Any:
    """Run one session-safe ninecli call with short-lived result caching.

    The cache is per authenticated session, never global, and only callers
    that explicitly provide a TTL receive cached data.  Identical concurrent
    calls share one task, so opening the app and refreshing a widget at the
    same time cannot launch duplicate ninecli processes.
    """
    key = tuple(args)
    now = time.monotonic()
    if cache_ttl > 0:
        cached = session.cache.get(key)
        if cached is not None:
            expires_at, value = cached
            if expires_at > now:
                return copy.deepcopy(value)
            session.cache.pop(key, None)

    task = session.inflight.get(key)
    if task is None or task.done():
        task = asyncio.create_task(_run_cloud_call(session, key))
        session.inflight[key] = task

    try:
        value = await asyncio.shield(task)
    finally:
        if task.done() and session.inflight.get(key) is task:
            session.inflight.pop(key, None)

    if cache_ttl > 0:
        session.cache[key] = (time.monotonic() + cache_ttl, copy.deepcopy(value))
    return copy.deepcopy(value)


@app.on_event("startup")
async def startup() -> None:
    global session_reaper_task
    SESSION_ROOT.mkdir(parents=True, exist_ok=True)
    try:
        SESSION_ROOT.chmod(0o700)
    except OSError as exc:
        # Some NAS bind mounts reject chmod even though the mounted directory
        # is already private and writable by the container user.
        logger.warning("could not chmod session root %s: %s", SESSION_ROOT, exc)
    restore_portal_sessions()
    session_reaper_task = asyncio.create_task(session_reaper())
    if not cli_available():
        logger.warning("ninecli is not available; login and vehicle APIs will be disabled")


@app.on_event("shutdown")
async def shutdown() -> None:
    global session_reaper_task
    if session_reaper_task is not None:
        session_reaper_task.cancel()
        try:
            await session_reaper_task
        except asyncio.CancelledError:
            pass
        session_reaper_task = None
    # Keep the mounted official-account config and portal sessions across
    # normal container shutdown/recreation. Logging out only ends the current
    # NinePlus session; it must not remove the installation-wide cloud binding.
    persist_portal_sessions()
    sessions.clear()


@app.exception_handler(RequestValidationError)
async def validation_error_handler(_: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content={
            "ok": False,
            "error": {"code": "validation_error", "message": "请求参数无效", "fields": exc.errors()},
        },
    )


@app.exception_handler(HTTPException)
async def http_error_handler(_: Request, exc: HTTPException):
    detail = exc.detail if isinstance(exc.detail, dict) else {
        "code": "request_error",
        "message": str(exc.detail),
    }
    return JSONResponse(
        status_code=exc.status_code,
        content={"ok": False, "error": detail},
        headers={"Cache-Control": "no-store"},
    )


@app.get("/", include_in_schema=False)
async def index():
    # The login page changed from a device-level official-account form to a
    # NinePlus-only form. Do not let browsers keep serving the old page from
    # cache after the server is upgraded.
    return FileResponse(
        APP_DIR / "static" / "index.html",
        headers={"Cache-Control": "no-store, no-cache, must-revalidate"},
    )


@app.get("/healthz")
async def healthz(response: Response):
    response.headers["Cache-Control"] = "no-store"
    return ok({
        "service": "nineplus",
        "version": app.version,
        "auth_mode": "per-login-session",
        "bearer_token_required": bool(APP_BEARER_TOKEN),
        "ninecli": cli_available(),
        "uptime_seconds": int(time.time() - BOOT_TIME),
        "active_sessions": len(sessions),
        "server_time": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
    })


def login_result(raw: Any, account: str, session_token: str, expires_at: float) -> dict[str, Any]:
    payload = raw if isinstance(raw, dict) else {}
    return {
        "uuid": payload.get("uuid") or payload.get("user_id") or payload.get("uid"),
        "phone": payload.get("phone") or payload.get("username") or account,
        "area_code": payload.get("area_code") or payload.get("areaCode") or "86",
        "region": payload.get("region") or "CN",
        "business_uid": payload.get("business_uid") or payload.get("businessUid"),
        "account_id": payload.get("account_id") or payload.get("accountId") or payload.get("id"),
        "session_token": session_token,
        "expires_at": expires_at,
    }


def portal_login_result(session: PortalSession, token: str) -> dict[str, Any]:
    cloud = session.cloud
    return {
        "username": session.username,
        "session_token": token,
        "expires_at": session.expires_at,
        # Kept for older clients. It describes server readiness, not a second
        # login step required on the current device.
        "official_account_bound": cloud is not None,
        "official_account": cloud.account if cloud is not None else None,
        "login_ready": True,
        "cloud_ready": cloud is not None,
    }


def set_session_cookie(request: Request, response: Response, token: str) -> None:
    response.set_cookie(
        "nineplus_session", token, max_age=SESSION_TTL, httponly=True,
        samesite="strict", secure=cookie_is_secure(request), path="/",
    )
    response.headers["Cache-Control"] = "no-store"


async def perform_portal_login(body: PortalLoginBody, request: Request, response: Response) -> dict[str, Any]:
    if not PORTAL_PASSWORD:
        error(503, "portal_not_configured", "NinePlus 登录密码尚未在服务器配置")
    username = body.username.strip()
    if not hmac.compare_digest(username, PORTAL_USERNAME) or not hmac.compare_digest(body.password, PORTAL_PASSWORD):
        error(401, "portal_login_failed", "NinePlus 用户名或密码不正确")

    token = secrets.token_urlsafe(32)
    portal = PortalSession(username, time.time() + SESSION_TTL)
    # The official cloud binding is installation-wide. A new browser, phone,
    # or tablet gets a fresh NinePlus session but never needs the official
    # account credentials again.
    async with official_binding_lock:
        attach_persistent_cloud(portal)
    sessions[token] = portal
    persist_portal_sessions()
    set_session_cookie(request, response, token)
    return portal_login_result(portal, token)


async def perform_official_login(body: OfficialLoginBody, request: Request, response: Response) -> dict[str, Any]:
    # The official Ninebot account is only a one-time server configuration.
    # It must never create an anonymous session or become an alternative
    # login path: every device first authenticates with NinePlus.
    token, portal = portal_from_request(request, request.cookies.get("nineplus_session"))

    if not cli_available():
        error(503, "dependency_missing", "ninecli 未安装")

    account = body.account.strip()
    # Login into a temporary sibling directory first. The existing binding
    # remains usable if the new credentials are rejected or ninecli times out.
    temp_dir = SESSION_ROOT / f".official-login-{secrets.token_hex(8)}"
    async with official_binding_lock:
        temp_dir.mkdir(parents=True, exist_ok=False)
        temp_cloud = CloudSession(account, temp_dir, portal.expires_at)
        prepare_cli_config(temp_dir, normalize_area_code(body.area_code))
        try:
            raw = await run_cli(temp_cloud, "login", "-u", account, password=body.password)
            # No cloud call can run concurrently while this lock is held.
            # Swap the verified config and its metadata as one recoverable
            # operation so a failed replacement keeps the old binding usable.
            replace_persistent_cloud(temp_dir, account)
            temp_cloud.config_dir = PERSISTENT_CLOUD_DIR

            # Preserve object identity for in-flight/request-local references
            # held by other sessions, then point every portal at the same
            # installation-wide CloudSession and clear stale response caches.
            canonical = next(
                (existing.cloud for existing in sessions.values()
                 if is_persistent_cloud(existing.cloud)),
                temp_cloud,
            )
            canonical.account = account
            canonical.config_dir = PERSISTENT_CLOUD_DIR
            canonical.expires_at = max(portal.expires_at, time.time() + SESSION_TTL)
            canonical.cache.clear()
            canonical.inflight.clear()
            for existing in sessions.values():
                if existing.cloud is not None and is_persistent_cloud(existing.cloud):
                    existing.cloud = canonical
            portal.cloud = canonical
            persist_portal_sessions()
        except Exception:
            cleanup_session(temp_cloud)
            raise

    set_session_cookie(request, response, token)
    return login_result(raw, account, token, portal.expires_at)


@app.post("/auth/login")
async def login(body: PortalLoginBody, request: Request, response: Response):
    return ok(await perform_portal_login(body, request, response))


@app.post("/ninebot/login")
async def ninebot_login(body: OfficialLoginBody, request: Request, response: Response):
    return ok(await perform_official_login(body, request, response))


@app.post("/accounts/login")
async def platform_compatible_login(body: OfficialLoginBody, request: Request, response: Response):
    # Kept as an explicit alias for older app builds; it still requires a
    # NinePlus portal session and only performs the cloud-account binding.
    return ok(await perform_official_login(body, request, response))


@app.post("/devices/register")
async def register_push_device(
    body: PushDeviceBody,
    request: Request,
    nineplus_session: str | None = Cookie(default=None),
):
    # A portal session is sufficient. The official account may be restored or
    # absent; device registration itself must not trigger a cloud login.
    _, portal = portal_from_request(request, nineplus_session)
    token = body.token.strip()
    bundle_id = body.bundle_id.strip()
    environment = body.environment.strip().lower()
    if not token or not bundle_id:
        error(422, "invalid_push_device", "设备通知注册参数不能为空")
    if environment not in {"development", "production", "sandbox"}:
        error(422, "invalid_push_environment", "APNs 环境必须是 development、production 或 sandbox")

    official_account = portal.cloud.account if portal.cloud is not None else None
    await _save_push_device(
        owner=portal.username,
        official_account=official_account,
        token=token,
        bundle_id=bundle_id,
        environment=environment,
    )
    logger.info(
        "registered push device owner=%s bundle_id=%s environment=%s",
        portal.username, bundle_id, environment,
    )
    return ok({
        "registered": True,
        "bundle_id": bundle_id,
        "environment": environment,
    })


@app.post("/auth/logout")
async def logout(request: Request, response: Response, nineplus_session: str | None = Cookie(default=None)):
    token, session = portal_from_request(request, nineplus_session)
    sessions.pop(token, None)
    cleanup_portal_session(session)
    persist_portal_sessions()
    response.delete_cookie("nineplus_session", path="/")
    response.headers["Cache-Control"] = "no-store"
    return ok()


@app.get("/auth/me")
async def me(request: Request, nineplus_session: str | None = Cookie(default=None)):
    token, session = portal_from_request(request, nineplus_session)
    async with official_binding_lock:
        attach_persistent_cloud(session)
        persist_portal_sessions()
    return ok(portal_login_result(session, token))


@app.post("/auth/refresh")
async def refresh_auth(request: Request, response: Response, nineplus_session: str | None = Cookie(default=None)):
    token, session = portal_from_request(request, nineplus_session)
    session.expires_at = time.time() + SESSION_TTL
    async with official_binding_lock:
        attach_persistent_cloud(session)
        if session.cloud is not None:
            session.cloud.expires_at = session.expires_at
    persist_portal_sessions()
    set_session_cookie(request, response, token)
    return ok(portal_login_result(session, token))


def vehicle_items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("vehicles", "data"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


def cached_total_mileage(sn: str) -> float | None:
    """Return the persisted trip-sum odometer fallback for older App builds.

    Some Ninebot models do not expose an odometer in ``status``. Older iOS
    clients reacted by downloading every month serially during the dashboard
    refresh, which left the UI stuck on “更新中”. The cache is generated once
    from the official trip records and is deliberately read-only here.
    """
    try:
        payload = json.loads(TOTAL_MILEAGE_CACHE.read_text(encoding="utf-8"))
        value = payload.get(sn, {}).get("total_mileage_odo")
        number = float(value)
        return number if number >= 0 else None
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def enrich_status_for_legacy_clients(sn: str, payload: Any) -> Any:
    if not isinstance(payload, dict):
        return payload
    existing = payload.get("total_mileage_odo")
    if existing is None:
        existing = payload.get("totalMileageOdo")
    if existing is not None:
        return payload
    mileage = cached_total_mileage(sn)
    if mileage is None:
        return payload
    enriched = copy.deepcopy(payload)
    enriched["total_mileage_odo"] = mileage
    enriched["total_mileage_source"] = "trip_sum_cache"
    return enriched


def current_month_string() -> str:
    # ninecli expects YYYYMM; use China time because the app displays China
    # calendar months even when the container host uses another timezone.
    return datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m")


async def dashboard_read(
    session: CloudSession,
    command: tuple[str, ...],
    cache_ttl: float,
) -> Any:
    try:
        return await cloud_call(session, *command, cache_ttl=cache_ttl)
    except HTTPException as exc:
        # Authentication errors must still fail the whole request.  A single
        # optional telemetry endpoint failing should not blank every vehicle.
        if exc.status_code in (401, 403):
            raise
        logger.warning("dashboard read failed (%s): %s", command[0], exc.detail)
        return None


@app.get("/vehicles")
async def vehicles(request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = await auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "vehicles", cache_ttl=CACHE_TTL_VEHICLES))


@app.get("/dashboard")
async def dashboard(
    request: Request,
    response: Response,
    month: str = "",
    nineplus_session: str | None = Cookie(default=None),
):
    """Return the home-screen data in one request.

    The underlying ninecli calls remain serialized per login session because
    they share token/config files, but the HTTP fan-out and duplicate calls are
    removed.  Each read also benefits from the session-level short TTL cache.
    """
    token, session = await auth_from_request(request, nineplus_session)
    owner = sessions[token].username
    normalized_month = normalize_month(month) or current_month_string()
    raw_vehicles = await cloud_call(session, "vehicles", cache_ttl=CACHE_TTL_VEHICLES)

    entries: list[dict[str, Any]] = []
    notification_vehicles: list[dict[str, Any]] = []
    for vehicle in vehicle_items(raw_vehicles):
        sn_value = vehicle.get("wnumber") or vehicle.get("sn")
        if not isinstance(sn_value, str) or not SN_PATTERN.fullmatch(sn_value):
            continue
        sn = validate_sn(sn_value)
        status = await dashboard_read(session, ("status", sn), CACHE_TTL_STATUS)
        status = normalize_status_location(status)
        battery = await dashboard_read(session, ("battery", sn), CACHE_TTL_BATTERY)
        travel = await dashboard_read(
            session,
            ("travel", sn, "--month", normalized_month),
            CACHE_TTL_TRAVEL,
        )
        entries.append({
            "vehicle": vehicle,
            "status": status,
            "battery": battery,
            "travel": travel,
        })
        notification_vehicles.append({
            "sn": sn,
            "vehicle_name": _vehicle_name(vehicle, sn),
            "status": status,
            "battery": battery,
        })

    await publish_vehicle_notifications(owner, notification_vehicles)

    response.headers["Cache-Control"] = "no-store"
    return ok({"month": normalized_month, "vehicles": entries, "updated_at": time.time()})


@app.get("/vehicles/{sn}/status")
async def vehicle_status(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = await auth_from_request(request, nineplus_session)
    normalized_sn = validate_sn(sn)
    payload = await cloud_call(session, "status", normalized_sn, cache_ttl=CACHE_TTL_STATUS)
    payload = enrich_status_for_legacy_clients(normalized_sn, payload)
    return ok(normalize_status_location(payload))


@app.get("/vehicles/{sn}/location")
async def vehicle_location(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = await auth_from_request(request, nineplus_session)
    payload = await cloud_call(session, "status", validate_sn(sn), cache_ttl=CACHE_TTL_STATUS)
    normalized = normalize_status_location(payload)
    if not isinstance(normalized, dict) or "location_coordinate" not in normalized:
        error(404, "location_unavailable", "九号云暂未返回有效定位数据")
    coordinate = normalized["location_coordinate"]
    return ok({
        "latitude": coordinate[0],
        "longitude": coordinate[1],
        "coordinate_system": "gcj02",
        "accuracy_meters": _number((normalized.get("loc") or {}).get("acc")) if isinstance(normalized.get("loc"), dict) else None,
        "updated_at": time.time(),
    })


@app.get("/vehicles/{sn}/battery")
async def vehicle_battery(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = await auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "battery", validate_sn(sn), cache_ttl=CACHE_TTL_BATTERY))


@app.get("/vehicles/{sn}/travel")
async def vehicle_travel(
    sn: str,
    request: Request,
    month: str = "",
    page: int = 1,
    page_size: int = 20,
    nineplus_session: str | None = Cookie(default=None),
):
    if page < 1 or page > 1000 or page_size < 1 or page_size > 100:
        error(400, "invalid_pagination", "分页参数超出范围")
    _, session = await auth_from_request(request, nineplus_session)
    normalized_month = normalize_month(month)
    payload = (
        await cloud_call(
            session,
            "travel",
            validate_sn(sn),
            "--month",
            normalized_month,
            cache_ttl=CACHE_TTL_TRAVEL,
        )
        if normalized_month
        else await cloud_call(session, "travel", validate_sn(sn), cache_ttl=CACHE_TTL_TRAVEL)
    )
    if isinstance(payload, list):
        start = (page - 1) * page_size
        return ok(payload[start:start + page_size])
    return ok(payload)


@app.get("/vehicles/{sn}/travel/{travel_id}")
async def travel_detail(
    sn: str,
    travel_id: str,
    request: Request,
    nineplus_session: str | None = Cookie(default=None),
):
    _, session = await auth_from_request(request, nineplus_session)
    payload = await cloud_call(session, "travel", validate_sn(sn), "--detail", validate_travel_id(travel_id))
    return ok(normalize_travel_detail(payload))


@app.post("/vehicles/{sn}/travel-sync")
async def travel_sync(
    sn: str,
    request: Request,
    month: str = "",
    page_size: int = 20,
    nineplus_session: str | None = Cookie(default=None),
):
    if page_size < 1 or page_size > 100:
        error(400, "invalid_pagination", "分页参数超出范围")
    _, session = await auth_from_request(request, nineplus_session)
    normalized_month = normalize_month(month) or current_month_string()
    payload = await cloud_call(
        session, "travel", validate_sn(sn), "--month", normalized_month,
        cache_ttl=CACHE_TTL_TRAVEL,
    )
    if isinstance(payload, list):
        all_rows = payload
        upstream_total = None
    elif isinstance(payload, dict):
        all_rows = payload.get("list") or payload.get("rows") or payload.get("records") or payload.get("travels") or []
        upstream_total = _number(payload.get("times") or payload.get("total"))
    else:
        all_rows = []
        upstream_total = None
    rows = all_rows[:page_size] if isinstance(all_rows, list) else []
    total = int(upstream_total) if upstream_total is not None else len(all_rows)
    return ok({
        "month": normalized_month,
        "page": 1,
        "page_size": page_size,
        "total": total,
        "items": rows,
        "records": rows,
        "has_more": total > len(rows),
    })


CONTROL_COMMANDS = {
    "bell": "bell",
    "buck": "buck",
    "engine_start": "engine-start",
    "engine_stop": "engine-stop",
}



def control_failure_message(result: Any) -> str | None:
    """Turn an explicit cloud rejection into an HTTP error.

    ninecli can exit with status 0 after receiving a well-formed cloud reply,
    even when that reply rejects the physical command. Checking the known
    result fields prevents the UI from showing “已完成” when the vehicle did
    not accept the action.
    """
    if not isinstance(result, dict):
        return None
    if result.get("ok") is False or result.get("success") is False:
        return str(
            result.get("message")
            or result.get("msg")
            or result.get("resultMsg")
            or result.get("error")
            or "九号云拒绝了车辆控制指令"
        )
    accepted = {None, "", 0, "0", 200, "200", True, "success", "ok", "SUCCESS", "OK"}
    for key in ("resultCode", "result_code", "errorCode", "error_code"):
        if key not in result or result[key] in accepted:
            continue
        return str(
            result.get("resultMsg")
            or result.get("result_msg")
            or result.get("message")
            or result.get("msg")
            or f"九号云返回控制错误码 {result[key]}"
        )
    return None


@app.post("/vehicles/{sn}/control")
async def vehicle_control(
    sn: str,
    body: ControlBody,
    request: Request,
    nineplus_session: str | None = Cookie(default=None),
):
    if not body.confirm:
        error(400, "confirmation_required", "远程控制必须明确确认")
    _, session = await auth_from_request(request, nineplus_session)
    control_args = [CONTROL_COMMANDS[body.action], validate_sn(sn)]
    if body.action != "bell":
        control_args.append("--yes")
    result = await cloud_call(session, *control_args)
    failure = control_failure_message(result)
    if failure is not None:
        logger.warning("vehicle control rejected action=%s sn=%s: %s", body.action, sn, failure[:240])
        error(502, "vehicle_control_rejected", failure)
    invalidate_session_cache(session)
    logger.info("vehicle control accepted action=%s sn=%s", body.action, sn)
    return ok(result)


@app.post("/vehicles/{sn}/bell")
async def ring_bell(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    return await vehicle_control(sn, ControlBody(action="bell", confirm=True), request, nineplus_session)


@app.post("/vehicles/{sn}/buck")
async def open_bucket(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    return await vehicle_control(sn, ControlBody(action="buck", confirm=True), request, nineplus_session)


@app.post("/vehicles/{sn}/engine/{mode}")
async def engine(
    sn: str,
    mode: str,
    request: Request,
    nineplus_session: str | None = Cookie(default=None),
):
    if mode not in {"start", "stop"}:
        error(400, "unsupported_action", "发动机动作必须是 start 或 stop")
    return await vehicle_control(
        sn,
        ControlBody(action=f"engine_{mode}", confirm=True),
        request,
        nineplus_session,
    )
