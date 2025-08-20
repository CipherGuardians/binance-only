#!/usr/bin/env bash
# Binance-only Shadowsocks gateway (sing-box 1.12.2 + glider)
# Usage (override via env):
#   SS_PORT=8388 SS_PASS="754213" UPSTREAM_HOST="207.148.99.63" UPSTREAM_PORT=8388 GLIDER_LOCAL_PORT=10808 bash binance-only.sh
set -euo pipefail

### ====== defaults (можно переопределить переменными окружения) ======
SS_PORT="${SS_PORT:-8388}"
SS_PASS="${SS_PASS:-754213}"
UPSTREAM_HOST="${UPSTREAM_HOST:-207.148.99.63}"
UPSTREAM_PORT="${UPSTREAM_PORT:-8388}"
GLIDER_LOCAL_PORT="${GLIDER_LOCAL_PORT:-10808}"
SINGBOX_VERSION="${SINGBOX_VERSION:-v1.12.2}"

log(){ echo -e "\033[1;32m[+] $*\033[0m"; }
warn(){ echo -e "\033[1;33m[!] $*\033[0m"; }
die(){ echo -e "\033[1;31m[!] $*\033[0m"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root (sudo)."

### ====== проверки окружения (docker обязателен, но НЕ устанавливается) ======
command -v docker >/dev/null 2>&1 || die "Docker не найден. Установи и запусти его заранее."
if ! systemctl is-active --quiet docker; then
  die "Сервис docker не запущен. Выполни: systemctl start docker"
fi

# вспомогательные утилиты: поставим только если отсутствуют
if ! command -v curl >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y curl ca-certificates
fi
if ! command -v nc >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y netcat-openbsd
fi

### ====== sing-box ======
if ! command -v sing-box >/dev/null 2>&1; then
  log "sing-box не найден — ставлю ${SINGBOX_VERSION}"
  curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "${SINGBOX_VERSION}"
else
  log "sing-box найден: $(sing-box version | head -n1)"
fi
SB_BIN="$(command -v sing-box)"

### ====== glider (локальный апстрим) ======
log "Запускаю/перезапускаю контейнер Glider на 127.0.0.1:${GLIDER_LOCAL_PORT}…"
docker rm -f proxy 2>/dev/null || true
docker run -d --name proxy --restart unless-stopped --network host \
  nadoo/glider \
  -verbose \
  -listen  ss://AEAD_AES_256_GCM:${SS_PASS}@127.0.0.1:${GLIDER_LOCAL_PORT} \
  -forward ss://AEAD_AES_256_GCM:${SS_PASS}@${UPSTREAM_HOST}:${UPSTREAM_PORT}

# ждём сокет glider
for i in $(seq 1 40); do nc -z 127.0.0.1 "${GLIDER_LOCAL_PORT}" && break; sleep 0.5; done
nc -z 127.0.0.1 "${GLIDER_LOCAL_PORT}" || die "Glider не слушает порт ${GLIDER_LOCAL_PORT}"

### ====== конфиг sing-box (совместим с 1.12.2) ======
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
      "type": "shadowsocks",
      "tag": "ss-glider",
      "server": "127.0.0.1",
      "server_port": ${GLIDER_LOCAL_PORT},
      "method": "aes-256-gcm",
      "password": "${SS_PASS}"
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
        "outbound": "ss-glider"
      },
      { "action": "reject" }
    ]
  }
}
EOF

log "Проверяю конфиг sing-box…"
"${SB_BIN}" check -c /etc/sing-box/config.json

### ====== systemd unit ======
log "Создаю systemd-юнит /etc/systemd/system/sing-box.service…"
cat >/etc/systemd/system/sing-box.service <<UNIT
[Unit]
Description=sing-box (SS server with Binance-only routing)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
User=root
Group=root
NoNewPrivileges=true
# ждём glider
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
