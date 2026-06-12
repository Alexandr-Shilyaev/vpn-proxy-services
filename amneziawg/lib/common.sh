#!/usr/bin/env bash
# common.sh — общие переменные и функции для всех скриптов AmneziaWG.
# Подключается через:  source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# ---------- Пути и константы ----------
WG_DIR="/etc/amnezia/amneziawg"          # awg-quick ищет конфиги здесь
WG_IFACE="${WG_IFACE:-awg0}"             # имя интерфейса
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"     # серверный конфиг
STATE_DIR="/etc/awg-vpn"                 # наше состояние (env, ключи, клиенты)
SERVER_ENV="${STATE_DIR}/server.env"     # параметры сервера
CLIENTS_DIR="${STATE_DIR}/clients"       # по одному каталогу на клиента

# ---------- Логирование ----------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
log()  { echo "${c_grn}[+]${c_rst} $*"; }
warn() { echo "${c_ylw}[!]${c_rst} $*" >&2; }
err()  { echo "${c_red}[x]${c_rst} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- Проверки ----------
need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root (sudo)."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

load_server_env() {
  [[ -f "${SERVER_ENV}" ]] || die "Нет ${SERVER_ENV}. Сначала запусти install_server.sh"
  # shellcheck disable=SC1090
  source "${SERVER_ENV}"
}

# ---------- Утилиты ----------
# Случайное целое в диапазоне [min, max] (включительно).
rand_int() {
  local min="$1" max="$2" range
  range=$(( max - min + 1 ))
  echo $(( (RANDOM * 32768 + RANDOM) % range + min ))
}

# Случайная hex-строка из N байт (по умолчанию 4). Для сигнатур обфускации.
rand_hex() {
  local n="${1:-4}"
  od -An -tx1 -N "${n}" /dev/urandom | tr -d ' \n'
}

# Валидация имени клиента: латиница, цифры, _ и -, до 32 символов.
validate_name() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9_-]{1,32}$ ]] \
    || die "Недопустимое имя клиента '${name}'. Разрешено: A-Z a-z 0-9 _ - (до 32 символов)."
}
