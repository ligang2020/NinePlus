#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot deployment helper for fnOS/Docker Compose.
# Run this script from the server directory on the NAS:
#   bash fnos-deploy.sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "错误：未找到 docker，请先在飞牛 fnOS 启用 Docker。" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "错误：当前 Docker 未安装 Compose v2（docker compose）。" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "已创建 server/.env，请先修改 NINEPLUS_PORTAL_PASSWORD 后重新运行。" >&2
  exit 2
fi

if grep -Eq '^NINEPLUS_PORTAL_PASSWORD=(请替换.*|change-me)$' .env || grep -q '^NINEPLUS_PORTAL_PASSWORD=$' .env; then
  echo "错误：请先在 server/.env 设置高强度 NINEPLUS_PORTAL_PASSWORD。" >&2
  exit 2
fi

# The image intentionally runs as uid/gid 10001. A bind mount keeps the data
# visible in the fnOS shared folder, so its ownership must match the container
# user before Compose starts.
mkdir -p persistent-sessions
if [[ "$(id -u)" == "0" ]]; then
  chown -R 10001:10001 persistent-sessions
else
  if ! touch persistent-sessions/.nineplus-write-test 2>/dev/null; then
    cat >&2 <<'MESSAGE'
错误：当前用户无法写入 persistent-sessions。
请用 fnOS 管理员 SSH 执行，或先执行：
  sudo chown -R 10001:10001 persistent-sessions
MESSAGE
    exit 1
  fi
  rm -f persistent-sessions/.nineplus-write-test
  echo "提示：当前不是 root；请确认 persistent-sessions 对容器 uid 10001 可写。"
fi
chmod 700 persistent-sessions

# This also validates interpolation before the build, including the optional
# Cloudflare profile (which is deliberately safe when its token is blank).
docker compose -f compose.yaml config >/dev/null
docker compose -f compose.yaml up -d --build
docker compose -f compose.yaml ps

PORT="${NINEPLUS_PORT:-}"
if [[ -z "$PORT" ]]; then
  PORT="$(sed -n 's/^NINEPLUS_PORT=//p' .env | tail -n 1)"
fi
PORT="${PORT:-8765}"
echo
echo "NinePlus 已启动： http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}"
echo "健康检查：     curl http://127.0.0.1:${PORT}/healthz"
