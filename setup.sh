#!/usr/bin/env bash
# setup.sh — единый bootstrap проекта vpn-proxy-services.
#
# Ставит выбранные протоколы (backend'ы) и поднимает ОДИН общий Telegram-бот,
# который управляет всеми ними.
#
# Сценарий на свежем VPS (Ubuntu 22.04/24.04):
#   git clone <repo> vpn-proxy-services && cd vpn-proxy-services
#   sudo ./setup.sh --token <BOT_TOKEN> --admins <id1,id2>
#
# Что делает:
#   1. копирует проект в /opt/vpn-proxy-services;
#   2. для каждого протокола из --protocols запускает его install_server.sh;
#   3. поднимает venv общего бота и ставит зависимости;
#   4. создаёт /etc/vpn-proxy-services/bot.env;
#   5. ставит и включает systemd-службу vpn-bot.
#
# Опции:
#   --token <t>        токен Telegram-бота (иначе спросит интерактивно)
#   --admins <ids>     id админов через запятую (иначе спросит)
#   --protocols <list> какие протоколы ставить, через запятую (по умолчанию: amneziawg)
#   --dir <path>       каталог установки (по умолчанию /opt/vpn-proxy-services)
#   --no-bot           только серверы протоколов, без бота
#   server-опции пробрасываются в install_server.sh протоколов:
#   --port, --subnet, --dns, --ip, --iface

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/vpn-proxy-services"
BOT_TOKEN=""
ADMIN_IDS=""
PROTOCOLS="amneziawg"
INSTALL_BOT=1
SRV_ARGS=()

c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
log()  { echo "${c_grn}[setup]${c_rst} $*"; }
warn() { echo "${c_ylw}[setup]${c_rst} $*" >&2; }
die()  { echo "${c_red}[setup] $*${c_rst}" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)     BOT_TOKEN="$2"; shift 2 ;;
    --admins)    ADMIN_IDS="$2"; shift 2 ;;
    --protocols) PROTOCOLS="$2"; shift 2 ;;
    --dir)       INSTALL_DIR="$2"; shift 2 ;;
    --no-bot)    INSTALL_BOT=0; shift ;;
    --port|--subnet|--dns|--ip|--iface)
                 SRV_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Запусти от root (sudo ./setup.sh ...)"

# ---------- 1. Копируем проект ----------
if [[ "${SRC_DIR}" != "${INSTALL_DIR}" ]]; then
  log "Копирую проект в ${INSTALL_DIR}…"
  mkdir -p "${INSTALL_DIR}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' --exclude '**/venv' --exclude '__pycache__' \
      "${SRC_DIR}/" "${INSTALL_DIR}/"
  else
    cp -a "${SRC_DIR}/." "${INSTALL_DIR}/"
    rm -rf "${INSTALL_DIR}/.git" "${INSTALL_DIR}/bot/venv" 2>/dev/null || true
  fi
else
  log "Запуск уже из ${INSTALL_DIR}."
fi
chmod +x "${INSTALL_DIR}"/setup.sh 2>/dev/null || true
find "${INSTALL_DIR}" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

# ---------- 2. Устанавливаем протоколы ----------
IFS=',' read -ra PROTO_LIST <<< "${PROTOCOLS}"
for proto in "${PROTO_LIST[@]}"; do
  proto="$(echo "${proto}" | xargs)"   # trim
  [[ -n "${proto}" ]] || continue
  installer="${INSTALL_DIR}/${proto}/install_server.sh"
  if [[ -x "${installer}" || -f "${installer}" ]]; then
    log "Устанавливаю протокол: ${proto}…"
    bash "${installer}" "${SRV_ARGS[@]}"
  else
    warn "Протокол '${proto}' ещё не реализован (нет ${installer}) — пропускаю."
  fi
done

# ---------- 3-5. Общий бот ----------
if [[ "${INSTALL_BOT}" -eq 0 ]]; then
  log "Флаг --no-bot: бот не ставится. Готово."
  exit 0
fi

[[ -n "${BOT_TOKEN}" ]] || read -rp "Введите BOT_TOKEN (от @BotFather): " BOT_TOKEN
[[ -n "${ADMIN_IDS}" ]] || read -rp "Введите ADMIN_IDS (ваш Telegram id, можно через запятую): " ADMIN_IDS
[[ -n "${BOT_TOKEN}" ]] || die "BOT_TOKEN не задан."
[[ -n "${ADMIN_IDS}" ]] || die "ADMIN_IDS не задан."

log "Готовлю окружение бота…"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-venv python3-pip >/dev/null

VENV="${INSTALL_DIR}/bot/venv"
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install --upgrade pip >/dev/null
"${VENV}/bin/pip" install -r "${INSTALL_DIR}/bot/requirements.txt"

mkdir -p /etc/vpn-proxy-services
cat > /etc/vpn-proxy-services/bot.env <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
REPO_DIR=${INSTALL_DIR}
EOF
chmod 600 /etc/vpn-proxy-services/bot.env

log "Ставлю systemd-службу vpn-bot…"
cat > /etc/systemd/system/vpn-bot.service <<EOF
[Unit]
Description=VPN/Proxy management Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/vpn-proxy-services/bot.env
WorkingDirectory=${INSTALL_DIR}/bot
ExecStart=${VENV}/bin/python ${INSTALL_DIR}/bot/bot.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-bot
sleep 1
systemctl --no-pager --full status vpn-bot | head -n 6 || true

echo
log "Готово. Протоколы и бот запущены."
echo "  Установка : ${INSTALL_DIR}"
echo "  Протоколы : ${PROTOCOLS}"
echo "  Бот       : vpn-bot.service (логи: journalctl -u vpn-bot -f)"
echo "  В Telegram : отправьте боту /start"
