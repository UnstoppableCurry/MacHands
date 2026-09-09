#!/bin/sh
# MacHands 中继安装脚本(systemd)。可以重复跑,跑几次结果都一样。
#
#   sudo sh relay/install.sh              从当前仓库安装到 /opt/machands
#   sudo PORT=443 sh relay/install.sh     换个端口
#
# 装完:systemctl status machands-relay / journalctl -u machands-relay -f
set -eu

PREFIX="${PREFIX:-/opt/machands}"
SERVICE="${SERVICE:-machands-relay}"
USER_NAME="${USER_NAME:-machands}"
PORT="${PORT:-8443}"
HOST="${HOST:-0.0.0.0}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "要用 root 跑:sudo sh relay/install.sh" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "没找到 node。先装 Node 20 以上(nvm / apt / dnf 都行),再跑一次这个脚本。" >&2
  exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "Node 版本太老($(node -v)),需要 20 以上。" >&2
  exit 1
fi

# 1. 系统用户(已经有就跳过)
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME" 2>/dev/null \
    || adduser --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
  echo "已创建系统用户 $USER_NAME"
else
  echo "系统用户 $USER_NAME 已存在,跳过"
fi

# 2. 代码:relay/ 和 agent/src/(中继会用到 agent/src/crypto.mjs)
mkdir -p "$PREFIX/relay" "$PREFIX/agent/src" "$PREFIX/relay/data"
cp -f "$SRC/relay/server.mjs" "$SRC/relay/package.json" "$PREFIX/relay/"
cp -f "$SRC/relay/config.example.json" "$PREFIX/relay/"
cp -f "$SRC/agent/src/crypto.mjs" "$SRC/agent/src/relay-server.mjs" "$PREFIX/agent/src/"

# 3. 依赖:只有一个 ws
if [ -d "$SRC/relay/node_modules/ws" ]; then
  mkdir -p "$PREFIX/relay/node_modules"
  cp -R "$SRC/relay/node_modules/." "$PREFIX/relay/node_modules/"
else
  (cd "$PREFIX/relay" && npm install --omit=dev --no-audit --no-fund)
fi

# 4. 配置(已经有就不覆盖,免得把你改过的端口冲掉)
if [ ! -f "$PREFIX/relay/config.json" ]; then
  cat > "$PREFIX/relay/config.json" <<EOF
{
  "host": "$HOST",
  "port": $PORT,
  "dataDir": "./data",
  "tls": null
}
EOF
  echo "已写入 $PREFIX/relay/config.json"
else
  echo "$PREFIX/relay/config.json 已存在,保留原样"
fi

chown -R "$USER_NAME":"$USER_NAME" "$PREFIX"
chmod 700 "$PREFIX/relay/data"

# 5. systemd
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=MacHands relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$PREFIX/relay
ExecStart=$(command -v node) $PREFIX/relay/server.mjs $PREFIX/relay/config.json
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$PREFIX/relay/data
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

sleep 1
if systemctl is-active --quiet "$SERVICE"; then
  echo
  echo "中继已启动,开机自启也开好了。"
  echo "  健康检查:curl -s http://127.0.0.1:$PORT/health"
  echo "  看日志:  journalctl -u $SERVICE -f"
  echo "  中继公钥:$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).relayId' 2>/dev/null || echo '(等服务起来后再看 /health)')"
else
  echo "服务没起来。看一眼:journalctl -u $SERVICE -n 50" >&2
  exit 1
fi
