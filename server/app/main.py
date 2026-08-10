from __future__ import annotations

import asyncio
import hmac
import copy
import json
import logging
import os
import re
import secrets
import hashlib
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Literal

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
# Keep the official ninecli token/config on the persistent session volume. The
# portal cookie is intentionally still short-lived/in-memory, but a new portal
# login will automatically re-attach this already-bound official account.
PERSISTENT_CLOUD_DIR = SESSION_ROOT / "official"
PERSISTENT_CLOUD_META = SESSION_ROOT / "official-account.json"
TOTAL_MILEAGE_CACHE = SESSION_ROOT / "total-mileage.json"
PUSH_DEVICES_FILE = SESSION_ROOT / "push-devices.json"
PORTAL_SESSIONS_FILE = SESSION_ROOT / "portal-sessions.json"
PORTAL_USERNAME = os.getenv("NINEPLUS_PORTAL_USERNAME", "gang").strip()
PORTAL_PASSWORD = os.getenv("NINEPLUS_PORTAL_PASSWORD", "")
# Separate installation token; never use the per-login session token as the
# deployment password and never commit this value to source control.
ACCESS_TOKEN = os.getenv("NINEPLUS_ACCESS_TOKEN", "").strip()
NINECLI_BIN = os.getenv("NINEPLUS_NINECLI_BIN", "").strip()
NINECLI_MODULE = os.getenv("NINEPLUS_NINECLI_MODULE", "ninecli").strip() or "ninecli"
DEVICE_ID = os.getenv("NINEPLUS_DEVICE_ID", "").strip().lower() or secrets.token_hex(16)
if not re.fullmatch(r"[0-9a-f]{32}", DEVICE_ID):
    raise RuntimeError("NINEPLUS_DEVICE_ID must be a 32-character hexadecimal value")

logger = logging.getLogger("nineplus")
logging.basicConfig(level=os.getenv("NINEPLUS_LOG_LEVEL", "INFO"))

app = FastAPI(
    title="NinePlus",
    version="1.2.1",
    description=(
        "Unofficial personal Ninebot web console. The backend invokes the "
        "community ninecli command-line client against the user-facing cloud service."
    ),
    docs_url="/api/docs",
    redoc_url=None,
)
app.mount("/assets", StaticFiles(directory=APP_DIR / "static"), name="assets")

_PUBLIC_PATHS = {"/", "/healthz", "/api/docs", "/openapi.json"}


def _access_token_from_request(request: Request) -> str:
    supplied = request.headers.get("x-nineplus-access-token", "").strip()
    authorization = request.headers.get("authorization", "")
    if not supplied and authorization.lower().startswith("bearer "):
        supplied = authorization[7:].strip()
    return supplied


@app.middleware("http")
async def require_access_token(request: Request, call_next):
    # Keep static assets and diagnostics reachable, but protect every API
    # endpoint (including both login endpoints) when a deployment token is
    # configured. The iOS app sends it as Authorization: Bearer.
    if ACCESS_TOKEN and (
        request.url.path in _PUBLIC_PATHS
        or request.url.path.startswith("/assets/")
    ):
        return await call_next(request)
    if ACCESS_TOKEN and not hmac.compare_digest(_access_token_from_request(request), ACCESS_TOKEN):
        return JSONResponse(
            status_code=401,
            content={
                "ok": False,
                "error": {
                    "code": "access_token_required",
                    "message": "需要填写 NinePlus 服务访问口令",
                },
            },
            headers={"Cache-Control": "no-store", "WWW-Authenticate": "Bearer"},
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
    """Restore the previously bound official account after a process restart."""
    if not PERSISTENT_CLOUD_DIR.is_dir() or not (PERSISTENT_CLOUD_DIR / "config.json").is_file():
        return None
    account = ""
    try:
        metadata = json.loads(PERSISTENT_CLOUD_META.read_text(encoding="utf-8"))
        account = str(metadata.get("account") or "").strip()
    except (OSError, ValueError, TypeError):
        logger.warning("persistent official account metadata is unreadable")
    if not account:
        logger.warning("persistent official config found without account metadata; ignoring it")
        return None
    logger.info("restored persistent official account binding for %s", account)
    return CloudSession(account, PERSISTENT_CLOUD_DIR, time.time() + SESSION_TTL)


def persist_official_account(account: str) -> None:
    PERSISTENT_CLOUD_DIR.mkdir(parents=True, exist_ok=True)
    PERSISTENT_CLOUD_META.write_text(
        json.dumps({"account": account}, ensure_ascii=False),
        encoding="utf-8",
    )
    PERSISTENT_CLOUD_META.chmod(0o600)


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
    """Persist portal tokens without storing either account password."""
    try:
        SESSION_ROOT.mkdir(parents=True, exist_ok=True)
        SESSION_ROOT.chmod(0o700)
        temporary = PORTAL_SESSIONS_FILE.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(_session_payload(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        os.replace(temporary, PORTAL_SESSIONS_FILE)
        PORTAL_SESSIONS_FILE.chmod(0o600)
    except OSError as exc:
        logger.error("could not persist NinePlus sessions: %s", exc)


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
            cloud = restore_persistent_cloud()
            if cloud is not None:
                cloud.expires_at = portal.expires_at
                portal.cloud = cloud
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
    # Keep one current token per portal user/app/environment and remove a
    # stale token when iOS rotates its APNs registration token.
    async with push_devices_lock:
        PUSH_DEVICES_FILE.parent.mkdir(parents=True, exist_ok=True)
        devices = _load_push_devices()
        retained = [
            item
            for item in devices
            if not (
                (item.get("owner") == owner
                 and item.get("bundle_id") == bundle_id
                 and item.get("environment") == environment)
                or item.get("token") == token
            )
        ]
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


def get_session(
    authorization: str | None,
    x_session: str | None,
    cookie_session: str | None,
) -> tuple[str, PortalSession]:
    # The iOS client intentionally has no account-login screen. When the
    # installation access token is supplied as Bearer auth, expose the
    # already-bound persistent cloud account as a lightweight app session.
    # This keeps the deployment token as the only credential required by the
    # frontend while preserving the existing cookie/session flow for the web UI.
    supplied_access_token = ""
    if authorization and authorization.lower().startswith("bearer "):
        supplied_access_token = authorization[7:].strip()
    if ACCESS_TOKEN and hmac.compare_digest(supplied_access_token, ACCESS_TOKEN) and not (x_session or cookie_session):
        token = "app-" + hashlib.sha256(ACCESS_TOKEN.encode("utf-8")).hexdigest()
        session = sessions.get(token)
        if session is None:
            session = PortalSession("app", time.time() + SESSION_TTL)
            session.cloud = restore_persistent_cloud()
            sessions[token] = session
        if session.cloud is None:
            error(409, "cloud_account_required", "服务端尚未绑定九号官方账号")
    else:
        token = x_session or cookie_session
        if not token and supplied_access_token:
            token = supplied_access_token
        if not token or token not in sessions:
            error(401, "not_authenticated", "请先连接 NinePlus 服务")
        session = sessions[token]

    now = time.time()
    if session.expires_at <= now:
        sessions.pop(token, None)
        cleanup_portal_session(session)
        persist_portal_sessions()
        error(401, "session_expired", "NinePlus 登录已过期，请重新登录")

    # Sliding renewal keeps an actively used app session alive indefinitely
    # while abandoned tokens still expire after the configured TTL.
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


def auth_from_request(request: Request, cookie: str | None) -> tuple[str, CloudSession]:
    token, portal = portal_from_request(request, cookie)
    if portal.cloud is None:
        error(409, "cloud_account_required", "请先绑定九号官方账号")
    return token, portal.cloud


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
                error(401, "login_failed", "九号云返回 90014：账号或密码不正确。请先确认九号官方 App 能使用同一账号登录")
            if any(marker in diagnostic_lower for marker in ("timeout", "deadline exceeded", "timed out", "i/o timeout")):
                error(504, "ninebot_cloud_timeout", "九号云登录请求超时，请检查服务器网络后重试")
            error(502, "ninebot_cloud_error", "九号云登录服务返回错误，请查看后端日志")
        error(502, "ninebot_cloud_error", "九号云请求失败，请稍后重试")
    return parse_cli_json(stdout)


async def _run_cloud_call(session: CloudSession, args: tuple[str, ...]) -> Any:
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
    SESSION_ROOT.chmod(0o700)
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
    # normal container shutdown/recreation. Explicit logout still removes them.
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
    return FileResponse(APP_DIR / "static" / "index.html")


@app.get("/healthz")
async def healthz():
    return ok({
        "service": "nineplus",
        "version": app.version,
        "ninecli": cli_available(),
        "uptime_seconds": int(time.time() - BOOT_TIME),
        "active_sessions": len(sessions),
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
        "official_account_bound": cloud is not None,
        "official_account": cloud.account if cloud is not None else None,
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
    # Re-attach the saved official account so users do not need to enter the
    # Ninebot cloud credentials after every container restart or portal login.
    portal.cloud = restore_persistent_cloud()
    sessions[token] = portal
    persist_portal_sessions()
    set_session_cookie(request, response, token)
    return portal_login_result(portal, token)


async def perform_official_login(body: OfficialLoginBody, request: Request, response: Response) -> dict[str, Any]:
    token, portal = portal_from_request(request, request.cookies.get("nineplus_session"))
    if not cli_available():
        error(503, "dependency_missing", "ninecli 未安装")

    if portal.cloud is not None:
        cleanup_session(portal.cloud)
        portal.cloud = None
        persist_portal_sessions()

    account = body.account.strip()
    # There is one installation-wide official binding. Reusing a stable path
    # makes ninecli credentials survive Uvicorn/Docker restarts; the directory
    # lives on the host-mounted session volume and is mode 0700.
    shutil.rmtree(PERSISTENT_CLOUD_DIR, ignore_errors=True)
    PERSISTENT_CLOUD_DIR.mkdir(parents=True, exist_ok=False)
    config_dir = PERSISTENT_CLOUD_DIR
    cloud = CloudSession(account, config_dir, portal.expires_at)
    prepare_cli_config(config_dir, normalize_area_code(body.area_code))
    try:
        raw = await run_cli(cloud, "login", "-u", account, password=body.password)
    except Exception:
        cleanup_session(cloud)
        raise

    persist_official_account(account)
    portal.cloud = cloud
    persist_portal_sessions()
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
    return ok(portal_login_result(session, token))


@app.post("/auth/refresh")
async def refresh_auth(request: Request, response: Response, nineplus_session: str | None = Cookie(default=None)):
    token, session = portal_from_request(request, nineplus_session)
    session.expires_at = time.time() + SESSION_TTL
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
    from datetime import datetime
    from zoneinfo import ZoneInfo

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
    _, session = auth_from_request(request, nineplus_session)
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
    _, session = auth_from_request(request, nineplus_session)
    normalized_month = normalize_month(month) or current_month_string()
    raw_vehicles = await cloud_call(session, "vehicles", cache_ttl=CACHE_TTL_VEHICLES)

    entries: list[dict[str, Any]] = []
    for vehicle in vehicle_items(raw_vehicles):
        sn_value = vehicle.get("wnumber") or vehicle.get("sn")
        if not isinstance(sn_value, str) or not SN_PATTERN.fullmatch(sn_value):
            continue
        sn = validate_sn(sn_value)
        status = await dashboard_read(session, ("status", sn), CACHE_TTL_STATUS)
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

    response.headers["Cache-Control"] = "no-store"
    return ok({"month": normalized_month, "vehicles": entries, "updated_at": time.time()})


@app.get("/vehicles/{sn}/status")
async def vehicle_status(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    normalized_sn = validate_sn(sn)
    payload = await cloud_call(session, "status", normalized_sn, cache_ttl=CACHE_TTL_STATUS)
    return ok(enrich_status_for_legacy_clients(normalized_sn, payload))


@app.get("/vehicles/{sn}/battery")
async def vehicle_battery(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
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
    _, session = auth_from_request(request, nineplus_session)
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
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "travel", validate_sn(sn), "--detail", validate_travel_id(travel_id)))


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
    _, session = auth_from_request(request, nineplus_session)
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
