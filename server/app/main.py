from __future__ import annotations

import asyncio
import logging
import os
import re
import secrets
import time
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any, Literal

from fastapi import Cookie, FastAPI, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

try:
    from ninecli.api import NinebotCloud
except ImportError:  # pragma: no cover - reported by /healthz
    NinebotCloud = None


APP_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.getenv("NINEPLUS_DATA_DIR", "/data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
SESSION_TTL = max(300, int(os.getenv("NINEPLUS_SESSION_TTL", "2592000")))
CLOUD_TIMEOUT = max(5, int(os.getenv("NINEPLUS_CLOUD_TIMEOUT", "30")))
COOKIE_SECURE = os.getenv("NINEPLUS_COOKIE_SECURE", "auto").lower()
BOOT_TIME = time.time()
SN_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")

logger = logging.getLogger("nineplus")
logging.basicConfig(level=os.getenv("NINEPLUS_LOG_LEVEL", "INFO"))

app = FastAPI(
    title="NinePlus",
    version="1.1.0",
    description=(
        "NinePlus is an unofficial personal web console for the Ninebot cloud "
        "client exposed by ninecli. It does not represent an official Ninebot API."
    ),
    docs_url="/api/docs",
    redoc_url=None,
)
app.mount("/assets", StaticFiles(directory=APP_DIR / "static"), name="assets")


class LoginBody(BaseModel):
    account: str = Field(min_length=3, max_length=128)
    password: str = Field(min_length=1, max_length=256)


class ControlBody(BaseModel):
    action: Literal["bell", "buck", "engine_start", "engine_stop"]
    confirm: bool = False


class CloudSession:
    def __init__(self, account: str, cloud: Any, expires_at: float):
        self.account = account
        self.cloud = cloud
        self.expires_at = expires_at
        # ninecli maintains authentication state; serialize calls per account.
        self.lock = asyncio.Lock()


sessions: dict[str, CloudSession] = {}


def serializable(value: Any) -> Any:
    """Convert ninecli's mixed dict/model/object responses to JSON-safe data."""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if is_dataclass(value):
        return serializable(asdict(value))
    if isinstance(value, dict):
        return {str(key): serializable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [serializable(item) for item in value]
    if hasattr(value, "model_dump"):
        return serializable(value.model_dump())
    if hasattr(value, "__dict__"):
        return {
            str(key): serializable(item)
            for key, item in vars(value).items()
            if not str(key).startswith("_")
        }
    return str(value)


def ok(data: Any = None) -> dict[str, Any]:
    return {"ok": True, "data": serializable(data if data is not None else {})}


def error(status: int, code: str, message: str) -> None:
    raise HTTPException(status_code=status, detail={"code": code, "message": message})


def cookie_is_secure(request: Request) -> bool:
    if COOKIE_SECURE in {"1", "true", "yes", "on"}:
        return True
    if COOKIE_SECURE in {"0", "false", "no", "off"}:
        return False
    return request.url.scheme == "https"


def get_session(
    authorization: str | None,
    x_session: str | None,
    cookie_session: str | None,
) -> tuple[str, CloudSession]:
    token = x_session or cookie_session
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    if not token or token not in sessions:
        error(401, "not_authenticated", "请先登录九号账号")

    session = sessions[token]
    if session.expires_at <= time.time():
        sessions.pop(token, None)
        error(401, "session_expired", "登录已过期，请重新登录")
    return token, session


def auth_from_request(request: Request, cookie: str | None) -> tuple[str, CloudSession]:
    return get_session(
        request.headers.get("authorization"),
        request.headers.get("x-nineplus-session"),
        cookie,
    )


def validate_sn(sn: str) -> str:
    if not SN_PATTERN.fullmatch(sn):
        error(400, "invalid_vehicle_sn", "车辆序列号格式无效")
    return sn



async def cloud_call(session: CloudSession, method: str, *args: Any, **kwargs: Any) -> Any:
    async with session.lock:
        operation = getattr(session.cloud, method, None)
        if operation is None:
            error(502, "unsupported_cloud_method", f"当前 ninecli 不支持 {method}")
        try:
            if asyncio.iscoroutinefunction(operation):
                result = await asyncio.wait_for(operation(*args, **kwargs), timeout=CLOUD_TIMEOUT)
            else:
                result = await asyncio.wait_for(
                    asyncio.to_thread(operation, *args, **kwargs), timeout=CLOUD_TIMEOUT
                )
            return serializable(result)
        except asyncio.TimeoutError:
            error(504, "ninebot_cloud_timeout", "九号云请求超时，请稍后重试")
        except HTTPException:
            raise
        except Exception as exc:
            # Keep upstream details out of the response: some client versions include
            # request fragments or account metadata in their exception text.
            logger.warning("ninebot operation failed: %s", method, exc_info=exc)
            error(502, "ninebot_cloud_error", "九号云请求失败，请稍后重试")


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
        "ninecli": NinebotCloud is not None,
        "uptime_seconds": int(time.time() - BOOT_TIME),
        "active_sessions": len(sessions),
    })


@app.post("/auth/login")
async def login(body: LoginBody, request: Request, response: Response):
    if NinebotCloud is None:
        error(503, "dependency_missing", "ninecli 未安装")

    account = body.account.strip()
    try:
        cloud = NinebotCloud(account, body.password)
        initialize = getattr(cloud, "initialize", None)
        if initialize is None:
            error(503, "dependency_invalid", "当前 ninecli 缺少登录接口")
        if asyncio.iscoroutinefunction(initialize):
            initialized = await asyncio.wait_for(initialize(), timeout=CLOUD_TIMEOUT)
        else:
            initialized = await asyncio.wait_for(asyncio.to_thread(initialize), timeout=CLOUD_TIMEOUT)
    except asyncio.TimeoutError:
        error(504, "login_timeout", "登录九号云超时，请稍后重试")
    except HTTPException:
        raise
    except Exception:
        logger.warning("ninebot login failed for account %s", account[:3] + "***")
        error(401, "login_failed", "九号账号或密码错误，或九号云暂时不可用")

    if initialized is False:
        error(401, "login_failed", "九号账号或密码错误")

    token = secrets.token_urlsafe(32)
    expires_at = time.time() + SESSION_TTL
    sessions[token] = CloudSession(account, cloud, expires_at)

    response.set_cookie(
        "nineplus_session",
        token,
        max_age=SESSION_TTL,
        httponly=True,
        samesite="strict",
        secure=cookie_is_secure(request),
        path="/",
    )
    response.headers["Cache-Control"] = "no-store"
    # Never return the session token in JSON; browser clients use the HttpOnly cookie.
    return ok({"account": account, "expires_at": expires_at})


@app.post("/auth/logout")
async def logout(request: Request, response: Response, nineplus_session: str | None = Cookie(default=None)):
    token, _ = auth_from_request(request, nineplus_session)
    sessions.pop(token, None)
    response.delete_cookie("nineplus_session", path="/")
    response.headers["Cache-Control"] = "no-store"
    return ok()


@app.get("/auth/me")
async def me(request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    return ok({"account": session.account, "expires_at": session.expires_at})


@app.get("/vehicles")
async def vehicles(request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "get_user_vehicles"))


@app.get("/vehicles/{sn}/status")
async def vehicle_status(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "get_current_vehicle_data", validate_sn(sn)))


@app.get("/vehicles/{sn}/battery")
async def vehicle_battery(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "get_battery_info", validate_sn(sn)))


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
    return ok(await cloud_call(
        session,
        "get_vehicle_travel",
        validate_sn(sn),
        page,
        page_size,
        month or None,
    ))


@app.get("/vehicles/{sn}/travel/{travel_id}")
async def travel_detail(
    sn: str,
    travel_id: str,
    request: Request,
    nineplus_session: str | None = Cookie(default=None),
):
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "get_travel_detail", validate_sn(sn), travel_id))


CONTROL_MAP = {
    "bell": "5",
    "buck": "3",
    "engine_start": "1",
    "engine_stop": "2",
}


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
    return ok(await cloud_call(session, "set_vehicle_control", validate_sn(sn), CONTROL_MAP[body.action]))


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
