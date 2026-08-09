from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import secrets
import shutil
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
COOKIE_SECURE = os.getenv("NINEPLUS_COOKIE_SECURE", "auto").lower()
BOOT_TIME = time.time()
SN_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
SESSION_ROOT = Path(os.getenv("NINEPLUS_SESSION_ROOT", "/run/nineplus/sessions"))
NINECLI_BIN = os.getenv("NINEPLUS_NINECLI_BIN", "ninecli")

logger = logging.getLogger("nineplus")
logging.basicConfig(level=os.getenv("NINEPLUS_LOG_LEVEL", "INFO"))

app = FastAPI(
    title="NinePlus",
    version="1.2.0",
    description=(
        "Unofficial personal Ninebot web console. The backend invokes the "
        "community ninecli command-line client against the user-facing cloud service."
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
    def __init__(self, account: str, config_dir: Path, expires_at: float):
        self.account = account
        self.config_dir = config_dir
        self.expires_at = expires_at
        self.lock = asyncio.Lock()


sessions: dict[str, CloudSession] = {}


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


def cli_available() -> bool:
    return bool(shutil.which(NINECLI_BIN) or Path(NINECLI_BIN).exists())


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


def cleanup_session(session: CloudSession) -> None:
    shutil.rmtree(session.config_dir, ignore_errors=True)


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
        cleanup_session(session)
        error(401, "session_expired", "登录已过期，请重新登录")
    return token, session


def auth_from_request(request: Request, cookie: str | None) -> tuple[str, CloudSession]:
    return get_session(
        request.headers.get("authorization"),
        request.headers.get("x-nineplus-session"),
        cookie,
    )


async def run_cli(
    session: CloudSession,
    *args: str,
    password: str | None = None,
) -> Any:
    """Run the real ninecli binary in a per-session ephemeral config directory."""
    command = [NINECLI_BIN, "--json", "--config", str(session.config_dir), *args]
    if password is not None:
        command.extend(["--password", password])
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
        logger.warning("ninecli operation failed (%s): %s", args[0] if args else "unknown", diagnostic[:240])
        if args and args[0] == "login":
            error(401, "login_failed", "九号账号或密码错误，或九号云暂时不可用")
        error(502, "ninebot_cloud_error", "九号云请求失败，请稍后重试")
    return parse_cli_json(stdout)


async def cloud_call(session: CloudSession, *args: str) -> Any:
    async with session.lock:
        return await run_cli(session, *args)


@app.on_event("startup")
async def startup() -> None:
    SESSION_ROOT.mkdir(parents=True, exist_ok=True)
    if not cli_available():
        logger.warning("ninecli is not available; login and vehicle APIs will be disabled")


@app.on_event("shutdown")
async def shutdown() -> None:
    for session in list(sessions.values()):
        cleanup_session(session)
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


@app.post("/auth/login")
async def login(body: LoginBody, request: Request, response: Response):
    if not cli_available():
        error(503, "dependency_missing", "ninecli 未安装")

    account = body.account.strip()
    token = secrets.token_urlsafe(32)
    config_dir = SESSION_ROOT / token
    config_dir.mkdir(parents=True, exist_ok=False)
    session = CloudSession(account, config_dir, time.time() + SESSION_TTL)
    try:
        # The CLI writes its authenticated token into this ephemeral config dir.
        await run_cli(session, "login", "--user", account, password=body.password)
    except Exception:
        cleanup_session(session)
        raise

    sessions[token] = session
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
    return ok({"account": account, "expires_at": session.expires_at})


@app.post("/auth/logout")
async def logout(request: Request, response: Response, nineplus_session: str | None = Cookie(default=None)):
    token, session = auth_from_request(request, nineplus_session)
    sessions.pop(token, None)
    cleanup_session(session)
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
    return ok(await cloud_call(session, "vehicles"))


@app.get("/vehicles/{sn}/status")
async def vehicle_status(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "status", validate_sn(sn)))


@app.get("/vehicles/{sn}/battery")
async def vehicle_battery(sn: str, request: Request, nineplus_session: str | None = Cookie(default=None)):
    _, session = auth_from_request(request, nineplus_session)
    return ok(await cloud_call(session, "battery", validate_sn(sn)))


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
    normalized_month = month.replace("-", "") if month else ""
    payload = await cloud_call(session, "travel", validate_sn(sn), "--month", normalized_month) if normalized_month else await cloud_call(session, "travel", validate_sn(sn))
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
    return ok(await cloud_call(session, "travel", validate_sn(sn), "--detail", travel_id))


CONTROL_COMMANDS = {
    "bell": "bell",
    "buck": "buck",
    "engine_start": "engine-start",
    "engine_stop": "engine-stop",
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
    return ok(await cloud_call(session, "-y", CONTROL_COMMANDS[body.action], validate_sn(sn)))


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
