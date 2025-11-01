#!/usr/bin/env bash
# Binance-only Shadowsocks gateway (latest sing-box + glider SOCKS)
# Usage (override via env):
#   SS_PORT=8388 SS_PASS="754213" UPSTREAM_HOST="207.148.99.63" UPSTREAM_PORT=8388 GLIDER_LOCAL_PORT=10808 bash binance-only.sh
set -euo pipefail

# ===== defaults =====
SS_PORT="${SS_PORT:-8388}"
SS_PASS="${SS_PASS:-345435}"
UPSTREAM_HOST="${UPSTREAM_HOST:-45.32.8.112}"
UPSTREAM_PORT="${UPSTREAM_PORT:-8388}"
GLIDER_LOCAL_PORT="${GLIDER_LOCAL_PORT:-10808}"

log(){ echo -e "\033[1;32m[+] $*\033[0m"; }
die(){ echo -e "\033[1;31m[!] $*\033[0m"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root (sudo)."

# ===== окружение =====
command -v docker >/dev/null 2>&1 || die "Docker не найден. Установи и запусти его заранее."
systemctl is-active --quiet docker || die "Сервис docker не запущен. Выполни: systemctl start docker"
command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl ca-certificates; }
command -v nc   >/dev/null 2>&1 || { apt-get update -y && apt-get install -y netcat-openbsd; }

# ===== sing-box: последняя стабильная =====
if ! command -v sing-box >/dev/null 2>&1; then
  log "sing-box не найден — ставлю последнюю стабильную"
  curl -fsSL https://sing-box.app/install.sh | bash
else
  log "sing-box найден: $(sing-box version | head -n1)"
fi
SB_BIN="$(command -v sing-box)"

# ===== glider: ЛОКАЛЬНЫЙ SOCKS5 (без SS на loopback) =====
log "Запускаю/перезапускаю Glider (SOCKS5) на 127.0.0.1:${GLIDER_LOCAL_PORT}…"
docker rm -f proxy 2>/dev/null || true
docker run -d --name proxy --restart unless-stopped --network host \
  nadoo/glider \
  -verbose \
  -listen socks5://127.0.0.1:${GLIDER_LOCAL_PORT} \
  -forward ss://AEAD_AES_256_GCM:${SS_PASS}@${UPSTREAM_HOST}:${UPSTREAM_PORT}

# ждём подъёма glider
for i in $(seq 1 40); do nc -z 127.0.0.1 "${GLIDER_LOCAL_PORT}" && break; sleep 0.5; done
nc -z 127.0.0.1 "${GLIDER_LOCAL_PORT}" || die "Glider не слушает порт ${GLIDER_LOCAL_PORT}"

# ===== конфиг sing-box =====
log "Пишу /etc/sing-box/config.json…"
install -d -m 0755 /etc/sing-box
cat >/etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },

  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": ${SS_PORT},
      "method": "aes-256-gcm",
      "password": "${SS_PASS}"
    }
  ],

  "outbounds": [
    {
      "type": "socks",
      "tag": "to-glider",
      "server": "127.0.0.1",
      "server_port": ${GLIDER_LOCAL_PORT}
    }
  ],

  "route": {
    "rules": [
      {
        "inbound": ["ss-in"],
        "domain": [
          "api.binance.com",
          "fapi.binance.com",
          "stream.binance.com",
          "fstream.binance.com"
        ],
        "outbound": "to-glider"
      },
      { "action": "reject" }
    ]
  }
}
EOF

log "Проверяю конфиг sing-box…"
"${SB_BIN}" check -c /etc/sing-box/config.json

# ===== systemd unit =====
log "Создаю systemd-юнит /etc/systemd/system/sing-box.service…"
cat >/etc/systemd/system/sing-box.service <<UNIT
[Unit]
Description=sing-box (SS server with Binance-only routing via local SOCKS glider)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
User=root
Group=root
NoNewPrivileges=true
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 40); do nc -z 127.0.0.1 ${GLIDER_LOCAL_PORT} && exit 0; sleep 0.5; done; echo "Glider:${GLIDER_LOCAL_PORT} не поднялся"; exit 1'
ExecStart=${SB_BIN} run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now sing-box
systemctl status --no-pager sing-box || true

log "Готово. Клиенты: ss://AES-256-GCM:${SS_PASS}@<SERVER_IP>:${SS_PORT}"

















