#!/usr/bin/env bash
# common.sh — общие переменные и функции для всех скриптов AmneziaWG.
# Подключается через:  source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# ---------- Пути и константы ----------
# Пути можно переопределить через окружение — это нужно тестам, которым не положено
# трогать реальные /etc. В обычной работе значения остаются такими, как ниже.
WG_DIR="${WG_DIR:-/etc/amnezia/amneziawg}"   # awg-quick ищет конфиги здесь
WG_IFACE="${WG_IFACE:-awg0}"             # имя интерфейса
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"     # серверный конфиг
STATE_DIR="${STATE_DIR:-/etc/awg-vpn}"   # наше состояние (env, ключи, клиенты)
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

# Случайный диапазон "lo-hi" вокруг базового значения base с разбросом ±spread.
# AmneziaWG 3.x принимает таймеры как диапазон (lo-hi) и на каждое срабатывание
# берёт из него случайное значение — это и ломает поведенческие сигнатуры.
# Нижняя граница не опускается ниже min (1 по умолчанию).
rand_range() {
  local base="$1" spread="$2" min="${3:-1}" lo hi
  lo=$(( base - spread )); (( lo < min )) && lo="${min}"
  hi=$(( base + spread ))
  echo "${lo}-${hi}"
}

# Случайный 32-байтный ключ в base64 — формат HeaderProtectionKey (как и PresharedKey).
# Парсер tools/модуля требует ровно 32 байта (CHACHA_KEY_SIZE), поэтому берём awg genpsk.
rand_key32() {
  awg genpsk
}

# ---------- AmneziaWG: параметры обфускации ----------
# Минимальный размер префикса S1-S4 при включённой Header Protection: первые 12 байт
# префикса служат nonce для ChaCha20, поэтому модуль отвергает конфиг с S* < 12
# (netlink.c: "S1 must be more then 12 to use headerProtection").
AWG_HP_MIN_S=12

# Подставляет дефолты для полей, появившихся в новых версиях: server.env, созданный
# старым install_server.sh, их не содержит, а при set -u обращение к ним упало бы.
awg_env_defaults() {
  : "${WG_MTU:=1280}"
  : "${WG_SUBNET6:=fd0a:1ce5:c0de}"
  : "${IPV6_ENABLED:=0}"
  : "${AWG_MODE:=legacy}"          # старые установки были в формате 1.x
  : "${AWG_S3:=}"                  # появились в 2.0
  : "${AWG_S4:=}"
  : "${AWG_I1:=}"
  : "${AWG_HP_KEY:=}"              # появились в 3.0/3.1
  : "${AWG_CPA:=}"
  : "${AWG_REKEY_AFTER:=}"
  : "${AWG_REKEY_TIMEOUT:=}"
  : "${AWG_REJECT_AFTER:=}"
  : "${AWG_KEEPALIVE_TIMEOUT:=}"
  : "${AWG_MAX_HANDSHAKES:=}"
  : "${AWG_RANDOM_TRAILERS:=}"
  : "${AWG_KEEPALIVE:=25}"         # PersistentKeepalive клиента (в 3.x — диапазон)
}

# Печатает блок параметров обфускации для секции [Interface].
# ВАЖНО: у сервера и у всех клиентов он должен быть ОДИНАКОВЫМ, поэтому и серверный,
# и клиентский конфиг, и миграция используют одну эту функцию.
# Пустые переменные не печатаются: в legacy нет S3/S4/I1, в 1.x/2.0 — параметров 3.x.
emit_awg_params() {
  echo "Jc = ${AWG_JC}"
  echo "Jmin = ${AWG_JMIN}"
  echo "Jmax = ${AWG_JMAX}"
  echo "S1 = ${AWG_S1}"
  echo "S2 = ${AWG_S2}"
  [[ -n "${AWG_S3}" ]] && echo "S3 = ${AWG_S3}"
  [[ -n "${AWG_S4}" ]] && echo "S4 = ${AWG_S4}"
  echo "H1 = ${AWG_H1}"
  echo "H2 = ${AWG_H2}"
  echo "H3 = ${AWG_H3}"
  echo "H4 = ${AWG_H4}"
  [[ -n "${AWG_I1}" ]] && echo "I1 = ${AWG_I1}"

  # --- AmneziaWG 3.x: шифрование заголовков, паддинг контента, рандомные тайминги ---
  if [[ -n "${AWG_HP_KEY}" ]]; then
    echo "HeaderProtectionKey = ${AWG_HP_KEY}"
  fi
  [[ -n "${AWG_CPA}" ]]                && echo "ContentPaddingAddition = ${AWG_CPA}"
  [[ -n "${AWG_REKEY_AFTER}" ]]        && echo "RekeyAfterTime = ${AWG_REKEY_AFTER}"
  [[ -n "${AWG_REKEY_TIMEOUT}" ]]      && echo "RekeyTimeout = ${AWG_REKEY_TIMEOUT}"
  [[ -n "${AWG_REJECT_AFTER}" ]]       && echo "RejectAfterTime = ${AWG_REJECT_AFTER}"
  [[ -n "${AWG_KEEPALIVE_TIMEOUT}" ]]  && echo "KeepaliveTimeout = ${AWG_KEEPALIVE_TIMEOUT}"
  [[ -n "${AWG_MAX_HANDSHAKES}" ]]     && echo "MaxHandshakeAttempts = ${AWG_MAX_HANDSHAKES}"
  [[ -n "${AWG_RANDOM_TRAILERS}" ]]    && echo "RandomTrailers = ${AWG_RANDOM_TRAILERS}"

  # Явный успех: последним мог оказаться невыполнившийся `[[ -n ... ]] && echo`,
  # а под `set -e` его код возврата уронил бы вызывающий скрипт.
  return 0
}

# Человекочитаемое название формата обфускации.
awg_mode_label() {
  case "${1:-${AWG_MODE}}" in
    v3)     echo "AmneziaWG 3.1 (шифрование заголовков + рандомные тайминги)" ;;
    v2)     echo "AmneziaWG 2.0 (имитация протокола, CPS)" ;;
    legacy) echo "AmneziaWG 1.x (Legacy)" ;;
    *)      echo "неизвестный формат '${1:-${AWG_MODE}}'" ;;
  esac
}

# ---------- Проверка версий пакетов ----------
AWG2_MIN_DATE="20250901"  # сборка amneziawg-tools с поддержкой формата 2.0 (релиз 2.0)
AWG3_MIN_DATE="20260812"  # сборка с поддержкой параметров 3.1 (тег v3.1.20260812)

# Достаёт максимальную дату-версию (YYYYMMDD) из версии deb-пакета.
# ВАЖНО: `awg --version` показывает базовую дату форка wireguard-tools (1.0.20210914) и НЕ
# меняется между релизами — по ней нельзя судить о версии протокола. Реальный релиз виден
# в версии пакета:
#   amneziawg-tools 1.0.20210914-0~202608130145+ee0f0a9~ubuntu24.04.1  ← 2026-08-13, коммит 3.1
#   amneziawg-dkms  1.0.0-0~202609061402+4569c4c~ubuntu24.04.1         ← 2026-09-06, тег 3.1
# Берём максимальную из всех дат строки версии — она и отражает фактический релиз.
pkg_date() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null \
    | grep -oE '20[0-9]{6}' | sort -rn | head -n1 || true
}

# Проверяет, что сборка пакета не старее минимальной. Возвращает:
#   0 — ок, 1 — слишком старая, 2 — версию прочитать не удалось.
pkg_date_at_least() {
  local pkg="$1" min="$2" d; d="$(pkg_date "${pkg}")"
  [[ -n "${d}" ]] || return 2
  [[ "${d}" -ge "${min}" ]] || return 1
  return 0
}

# Проверяет на временном интерфейсе, что загруженные tools И модуль ядра действительно
# принимают параметры формата. Нужно потому, что версия deb-пакета врёт о возможностях:
# если DKMS не собрался под текущее ядро, пакет новый, а .ko в ядре остался прежним.
# Возвращает 0, если формат принят или проверить не удалось (тогда не блокируем), 1 — отказ.
probe_awg_support() {
  local mode="$1" iface="awgp$$" conf rc=0
  [[ "${mode}" == "legacy" ]] && return 0
  command -v ip >/dev/null 2>&1 || return 0

  if ! ip link add dev "${iface}" type amneziawg >/dev/null 2>&1; then
    warn "Не удалось создать тестовый интерфейс amneziawg — пропускаю проверку модуля."
    warn "Если модуль не собран под $(uname -r), служба не поднимется: dkms status amneziawg"
    return 0
  fi

  conf="$(mktemp)"
  {
    echo "[Interface]"
    echo "PrivateKey = $(awg genkey)"
    echo "Jc = 4"; echo "Jmin = 64"; echo "Jmax = 512"
    echo "S1 = 16"; echo "S2 = 16"; echo "S3 = 16"; echo "S4 = 16"
    echo "H1 = 1"; echo "H2 = 2"; echo "H3 = 3"; echo "H4 = 4"
    echo "I1 = <b 0xdeadbeef><rc 8><t><r 40>"
    if [[ "${mode}" == "v3" ]]; then
      echo "HeaderProtectionKey = $(awg genpsk)"
      echo "ContentPaddingAddition = 0-24"
      echo "RekeyAfterTime = 110-130"
      echo "RandomTrailers = on"
    fi
  } > "${conf}"

  awg setconf "${iface}" "${conf}" >/dev/null 2>&1 || rc=1
  rm -f "${conf}"
  ip link del dev "${iface}" >/dev/null 2>&1 || true
  return "${rc}"
}

# Гарантирует, что установленные tools и модуль понимают формат $1 (по умолчанию AWG_MODE).
# Формат 2.0 — сборка >= AWG2_MIN_DATE, формат 3.1 — >= AWG3_MIN_DATE (и tools, и dkms:
# netlink-интерфейс 3.1 задаётся модулем, а имена ключей конфига разбирают tools).
ensure_awg_version() {
  local mode="${1:-${AWG_MODE}}" min label fallback
  case "${mode}" in
    v3)     min="${AWG3_MIN_DATE}"; label="3.1"; fallback="--awg2" ;;
    v2)     min="${AWG2_MIN_DATE}"; label="2.0"; fallback="--legacy" ;;
    legacy) return 0 ;;
    *)      die "Неизвестный формат обфускации: ${mode}" ;;
  esac

  local pkg rc
  for pkg in amneziawg-tools amneziawg-dkms; do
    pkg_date_at_least "${pkg}" "${min}" && continue
    rc=$?
    if [[ "${rc}" -eq 2 ]]; then
      warn "Не удалось прочитать версию пакета ${pkg} (dpkg-query)."
      warn "Если служба не поднимется — обнови пакеты или вернись на формат ${fallback}."
      continue
    fi
    err "Сборка ${pkg} $(pkg_date "${pkg}"), а для формата ${label} нужна >= ${min}."
    err "Обнови пакеты:"
    err "  sudo add-apt-repository ppa:amnezia/ppa && sudo apt-get update"
    die "  sudo apt-get install --only-upgrade -y amneziawg amneziawg-tools amneziawg-dkms"
  done

  # Версии пакетов сошлись — теперь проверяем фактическую поддержку в ядре.
  if ! probe_awg_support "${mode}"; then
    err "Загруженный модуль AmneziaWG не принял параметры формата ${label}."
    err "Версии пакетов подходят, значит в ядре работает старый модуль — скорее всего"
    err "DKMS не собрался под текущее ядро $(uname -r)."
    err "Что проверить:"
    err "  dkms status amneziawg          # должен быть 'installed' для $(uname -r)"
    err "  sudo apt-get install -y linux-headers-\$(uname -r)"
    err "  sudo dkms autoinstall && sudo modprobe -r amneziawg && sudo modprobe amneziawg"
    err "Если модуль под это ядро не собирается — перезагрузись в ядро, где он собран,"
    err "либо используй формат ${fallback}."
    die "Прерываю, чтобы не ломать рабочий сервер."
  fi
  log "amneziawg-tools/dkms и модуль ядра — формат ${label} поддерживается."
}

# ---------- Генерация параметров обфускации ----------
# Должны совпадать у сервера и всех клиентов. Генерируем по логике приложения Amnezia.
# Заполняет глобальные AWG_* согласно AWG_MODE (v3 | v2 | legacy).
gen_obfuscation() {
  # Поля, которых нет в старых форматах, по умолчанию пустые — emit_awg_params их пропустит.
  AWG_S3=""; AWG_S4=""; AWG_I1=""          # появились в 2.0
  AWG_HP_KEY=""; AWG_CPA=""                # появились в 3.0
  AWG_REKEY_AFTER=""; AWG_REKEY_TIMEOUT=""; AWG_REJECT_AFTER=""
  AWG_KEEPALIVE_TIMEOUT=""; AWG_MAX_HANDSHAKES=""; AWG_RANDOM_TRAILERS=""
  AWG_KEEPALIVE="25"                       # PersistentKeepalive клиента

  # H1..H4 — «магические» значения типов пакетов. В 1.x/2.0 они идут по сети открытым
  # текстом, поэтому там их рандомизируют. В 3.1 заголовок шифруется (Header Protection),
  # так что рандомизация смысла не имеет: документация Amnezia предписывает оставить
  # совместимые значения 1,2,3,4 (диапазоны H1-H4 при этом не должны пересекаться).
  if [[ "${AWG_MODE}" == "v3" ]]; then
    AWG_H1=1; AWG_H2=2; AWG_H3=3; AWG_H4=4
  else
    AWG_H1="$(rand_int 5 2000000000)"
    AWG_H2="$(rand_int 5 2000000000)"; while [[ "${AWG_H2}" == "${AWG_H1}" ]]; do AWG_H2="$(rand_int 5 2000000000)"; done
    AWG_H3="$(rand_int 5 2000000000)"; while [[ "${AWG_H3}" == "${AWG_H1}" || "${AWG_H3}" == "${AWG_H2}" ]]; do AWG_H3="$(rand_int 5 2000000000)"; done
    AWG_H4="$(rand_int 5 2000000000)"; while [[ "${AWG_H4}" == "${AWG_H1}" || "${AWG_H4}" == "${AWG_H2}" || "${AWG_H4}" == "${AWG_H3}" ]]; do AWG_H4="$(rand_int 5 2000000000)"; done
  fi

  case "${AWG_MODE}" in
    legacy)
      # --- AmneziaWG 1.x (Legacy): шумовая обфускация, совместима со старыми клиентами ---
      AWG_JC="$(rand_int 4 12)"
      AWG_JMIN="$(rand_int 16 64)"
      AWG_JMAX="$(rand_int 512 1280)"
      AWG_S1="$(rand_int 15 150)"
      AWG_S2="$(rand_int 15 150)"
      while [[ $(( AWG_S1 + 56 )) -eq "${AWG_S2}" ]]; do AWG_S2="$(rand_int 15 150)"; done  # S1+56 != S2
      ;;
    v2)
      # --- AmneziaWG 2.0: имитация протокола (CPS) + универсальное заполнение ---
      AWG_JC="$(rand_int 3 8)"        # кол-во junk-пакетов после I1 (диапазон 0–10)
      AWG_JMIN="$(rand_int 64 200)"   # размер junk-пакетов (диапазон 64–1024)
      AWG_JMAX="$(rand_int 400 1024)"
      AWG_S1="$(rand_int 0 64)"       # префиксы Init/Response/Cookie (0–64)
      AWG_S2="$(rand_int 0 64)"
      AWG_S3="$(rand_int 0 64)"
      AWG_S4="$(rand_int 0 32)"       # префикс Data-пакетов (0–32)
      # I1 — сигнатурный пакет имитации (CPS): фикс. магия + случайные буквы + время + случайный хвост.
      # Сервер и клиенты используют ОДНУ И ТУ ЖЕ строку (как и остальные параметры обфускации).
      AWG_I1="<b 0x$(rand_hex 4)><rc 8><t><r $(rand_int 30 80)>"
      ;;
    v3)
      # --- AmneziaWG 3.1: всё из 2.0 + шифрование заголовков и рандомные тайминги ---
      AWG_JC="$(rand_int 3 8)"
      AWG_JMIN="$(rand_int 64 200)"
      AWG_JMAX="$(rand_int 400 1024)"
      AWG_I1="<b 0x$(rand_hex 4)><rc 8><t><r $(rand_int 30 80)>"

      # S1-S4 — один и тот же размер префикса для всех четырёх типов пакетов. Два жёстких
      # требования 3.1: (1) при Header Protection каждый S* >= 12, т.к. первые 12 байт
      # префикса служат nonce для ChaCha20 (иначе модуль отвергнет конфиг);
      # (2) при RandomTrailers документация предписывает одинаковое значение для S1-S4.
      local s; s="$(rand_int $(( AWG_HP_MIN_S + 4 )) 64)"
      AWG_S1="${s}"; AWG_S2="${s}"; AWG_S3="${s}"; AWG_S4="${s}"

      # Header Protection: шифрует заголовок пакета (тип/индексы) ChaCha20 на этом ключе.
      # Ровно 32 байта base64, ОДИНАКОВЫЙ у сервера и клиента — иначе связи не будет.
      AWG_HP_KEY="$(rand_key32)"

      # Паддинг контента: случайные байты внутри шифротекста вместо выравнивания WG по 16 —
      # ломает характерную «ступенчатую» гистограмму размеров пакетов.
      AWG_CPA="0-$(rand_int 16 48)"

      # Рандомные тайминги (секунды): модуль берёт случайное значение из диапазона на каждое
      # срабатывание таймера, поэтому исчезает периодичность, по которой ТСПУ узнаёт WG.
      # Инвариант: верх RekeyAfterTime должен быть ниже низа RejectAfterTime, иначе сессия
      # может быть отброшена раньше, чем произойдёт перегенерация ключей.
      AWG_REKEY_AFTER="$(rand_range "$(rand_int 110 130)" 20)"        # штатно 120
      AWG_REJECT_AFTER="$(rand_range "$(rand_int 185 200)" 15)"       # штатно 180
      AWG_REKEY_TIMEOUT="$(rand_range 5 2)"                           # штатно 5
      AWG_KEEPALIVE_TIMEOUT="$(rand_range "$(rand_int 10 12)" 3)"     # штатно 10
      AWG_MAX_HANDSHAKES="$(rand_range 18 4)"                         # штатно 18

      # Случайные «хвосты» в handshake-пакетах. Обязательно с двух сторон.
      AWG_RANDOM_TRAILERS="on"

      # PersistentKeepalive клиента тоже диапазон: фиксированные 25 с — сами по себе
      # заметная сигнатура (ровный пульс каждые 25 секунд).
      AWG_KEEPALIVE="$(rand_range 24 6)"
      ;;
    *) die "Неизвестный формат обфускации: ${AWG_MODE}" ;;
  esac
}

# ---------- Рендеринг конфигов ----------
# Печатает секцию [Interface] серверного конфига (без [Peer] — их добавляет add_user.sh).
# Используют и install_server.sh, и migrate.sh, чтобы формат был ровно один.
render_server_iface() {
  local addr="${WG_SUBNET}.1/24"
  [[ "${IPV6_ENABLED}" -eq 1 ]] && addr="${addr}, ${WG_SUBNET6}::1/64"

  echo "[Interface]"
  echo "Address = ${addr}"
  echo "ListenPort = ${WG_PORT}"
  echo "PrivateKey = ${SERVER_PRIVKEY}"
  echo "MTU = ${WG_MTU}"
  echo "# NAT и форвардинг включаются при старте/остановке интерфейса"
  echo "PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_SUBNET}.0/24 -o ${WAN_IFACE} -j MASQUERADE"
  echo "PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_SUBNET}.0/24 -o ${WAN_IFACE} -j MASQUERADE"
  if [[ "${IPV6_ENABLED}" -eq 1 ]]; then
    echo "PostUp   = ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -s ${WG_SUBNET6}::/64 -o ${WAN_IFACE} -j MASQUERADE"
    echo "PostDown = ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -s ${WG_SUBNET6}::/64 -o ${WAN_IFACE} -j MASQUERADE"
  fi
  echo ""
  echo "# --- Обфускация: $(awg_mode_label) ---"
  emit_awg_params
}

# Печатает клиентский конфиг целиком.
# Аргументы: <privkey> <psk> <address> <dns> <mtu> <allowed_ips>
render_client_conf() {
  local priv="$1" psk="$2" addr="$3" dns="$4" mtu="$5" allowed="$6"
  echo "[Interface]"
  echo "Address = ${addr}"
  echo "DNS = ${dns}"
  echo "PrivateKey = ${priv}"
  echo "MTU = ${mtu}"
  emit_awg_params
  echo ""
  echo "[Peer]"
  echo "PublicKey = ${SERVER_PUBKEY}"
  echo "PresharedKey = ${psk}"
  echo "Endpoint = ${SERVER_IP}:${WG_PORT}"
  echo "AllowedIPs = ${allowed}"
  echo "PersistentKeepalive = ${AWG_KEEPALIVE}"
}

# Пишет состояние сервера в ${SERVER_ENV} из текущих глобальных переменных.
# Используют install_server.sh (первая установка) и migrate.sh (смена формата).
write_server_env() {
  cat > "${SERVER_ENV}" <<EOF
# Состояние сервера AmneziaWG. Обновлено $(date -u +%FT%TZ)
SERVER_IP="${SERVER_IP}"
WAN_IFACE="${WAN_IFACE}"
WG_IFACE="${WG_IFACE}"
WG_PORT="${WG_PORT}"
WG_SUBNET="${WG_SUBNET}"
WG_SUBNET6="${WG_SUBNET6}"
WG_DNS="${WG_DNS}"
WG_MTU="${WG_MTU}"
IPV6_ENABLED="${IPV6_ENABLED}"
SERVER_PRIVKEY="${SERVER_PRIVKEY}"
SERVER_PUBKEY="${SERVER_PUBKEY}"
# --- параметры обфускации (одинаковые у сервера и клиентов) ---
AWG_MODE="${AWG_MODE}"
AWG_JC="${AWG_JC}"
AWG_JMIN="${AWG_JMIN}"
AWG_JMAX="${AWG_JMAX}"
AWG_S1="${AWG_S1}"
AWG_S2="${AWG_S2}"
AWG_S3="${AWG_S3}"
AWG_S4="${AWG_S4}"
AWG_H1="${AWG_H1}"
AWG_H2="${AWG_H2}"
AWG_H3="${AWG_H3}"
AWG_H4="${AWG_H4}"
AWG_I1="${AWG_I1}"
# --- параметры AmneziaWG 3.x (в форматах 1.x/2.0 пустые) ---
AWG_HP_KEY="${AWG_HP_KEY}"
AWG_CPA="${AWG_CPA}"
AWG_REKEY_AFTER="${AWG_REKEY_AFTER}"
AWG_REKEY_TIMEOUT="${AWG_REKEY_TIMEOUT}"
AWG_REJECT_AFTER="${AWG_REJECT_AFTER}"
AWG_KEEPALIVE_TIMEOUT="${AWG_KEEPALIVE_TIMEOUT}"
AWG_MAX_HANDSHAKES="${AWG_MAX_HANDSHAKES}"
AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS}"
AWG_KEEPALIVE="${AWG_KEEPALIVE}"
EOF
  chmod 600 "${SERVER_ENV}"
}

# Достаёт значение ключа из ini-подобного конфига: get_conf_value <файл> <ключ>.
# Берёт первое вхождение, обрезает пробелы. Нужен миграции, чтобы сохранить
# индивидуальные значения клиента (ключи, PSK, свой DNS/MTU).
get_conf_value() {
  local file="$1" key="$2"
  awk -v k="${key}" -F= '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }' "${file}" 2>/dev/null || true
}

# Пересобирает .conf и QR существующего клиента под ТЕКУЩИЕ параметры обфускации.
# Ключи клиента и PSK берём из его старого .conf (больше мы их нигде не храним),
# адрес — из файлов состояния ip/ip6, индивидуальные DNS/MTU сохраняем как были.
# Возвращает 1, если клиента пересобрать нельзя (вызывающий решает, что делать).
regen_client_conf() {
  local name="$1"
  local dir="${CLIENTS_DIR}/${name}"
  local conf="${dir}/${name}.conf"
  local priv psk dns mtu ip ip6 addr allowed

  if [[ ! -f "${conf}" ]]; then
    warn "Клиент '${name}': нет ${conf} — пропускаю (пересоздай через add_user.sh)."
    return 1
  fi

  priv="$(get_conf_value "${conf}" PrivateKey)"
  psk="$(get_conf_value "${conf}" PresharedKey)"
  if [[ -z "${priv}" ]]; then
    warn "Клиент '${name}': в конфиге нет PrivateKey — пропускаю."
    return 1
  fi

  dns="$(get_conf_value "${conf}" DNS)";  [[ -n "${dns}" ]] || dns="${WG_DNS}"
  mtu="$(get_conf_value "${conf}" MTU)";  [[ -n "${mtu}" ]] || mtu="${WG_MTU}"

  ip="$(cat "${dir}/ip" 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    addr="${ip}/32"
    allowed="0.0.0.0/0"
    # IPv6 добавляем только если он включён на сервере: иначе ::/0 завернул бы
    # IPv6-трафик в туннель, где его некуда выпустить (чёрная дыра/утечка).
    if [[ "${IPV6_ENABLED}" -eq 1 ]]; then
      ip6="$(cat "${dir}/ip6" 2>/dev/null || true)"
      [[ -n "${ip6}" ]] || ip6="${WG_SUBNET6}::${ip##*.}"
      echo "${ip6}" > "${dir}/ip6"
      addr="${addr}, ${ip6}/128"
      allowed="${allowed}, ::/0"
    fi
  else
    # Файла ip нет (очень старая установка) — берём адрес и маршруты из конфига.
    addr="$(get_conf_value "${conf}" Address)"
    allowed="$(get_conf_value "${conf}" AllowedIPs)"
    if [[ -z "${addr}" ]]; then
      warn "Клиент '${name}': не удалось определить адрес — пропускаю."
      return 1
    fi
    [[ -n "${allowed}" ]] || allowed="0.0.0.0/0"
  fi

  render_client_conf "${priv}" "${psk}" "${addr}" "${dns}" "${mtu}" "${allowed}" > "${conf}.new"
  chmod 600 "${conf}.new"
  mv "${conf}.new" "${conf}"
  qrencode -t PNG -o "${dir}/${name}.png" < "${conf}"
  return 0
}

# Валидация имени клиента: латиница, цифры, _ и -, до 32 символов.
validate_name() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9_-]{1,32}$ ]] \
    || die "Недопустимое имя клиента '${name}'. Разрешено: A-Z a-z 0-9 _ - (до 32 символов)."
}
