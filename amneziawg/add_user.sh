#!/usr/bin/env bash
# add_user.sh — (б) добавить клиента AmneziaWG.
#
# Делает:
#   - генерирует ключи клиента (приватный, публичный, preshared);
#   - выдаёт следующий свободный IP в подсети;
#   - добавляет [Peer] в серверный конфиг и применяет на лету (awg syncconf);
#   - формирует клиентский .conf (с параметрами обфускации AmneziaWG);
#   - рисует QR-код (.png) для импорта в приложении Amnezia / AmneziaWG.
#
# Использование:
#   sudo ./add_user.sh <имя_клиента> [--dns ...] [--mtu ...]
#         [--exclude-country ru] [--exclude-asn AS47541] [--exclude 1.2.3.0/24] [--aggregate 16]
#
#   --dns <list>          переопределить DNS только для этого клиента (по умолчанию серверный)
#   --mtu <n>             переопределить MTU только для этого клиента (по умолчанию серверный)
#   split-tunnel — увести трафик к этим сетям МИМО VPN (AllowedIPs = всё минус исключения):
#   --exclude-country <cc>  страны (RIPEstat), напр. ru — «весь рунет напрямую»
#   --exclude-asn <as>      автономные системы, напр. AS47541
#   --exclude <cidr>        произвольные подсети, напр. 10.20.0.5/32
#   --aggregate <N>         огрублять v4-исключения до /N → меньше диапазонов (с допуском)
#   Дефолты исключений берутся из server.env (EXCLUDE_COUNTRIES/ASNS/CIDRS, AGGREGATE) —
#   так бот-клиенты тоже наследуют split-tunnel без флагов.
#
# Печатает в stdout строку:  CONF=<путь> QR=<путь>
# (бот парсит её, чтобы отправить файлы в Telegram).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root
load_server_env
need_cmd awg
need_cmd awg-quick
need_cmd qrencode

# Дефолты для значений, появившихся в новых версиях (старый server.env их не содержит).
: "${WG_MTU:=1280}"
: "${WG_SUBNET6:=fd0a:1ce5:c0de}"
: "${IPV6_ENABLED:=0}"
: "${AWG_S3:=}"
: "${AWG_S4:=}"
: "${AWG_I1:=}"
# split-tunnel: глобальные дефолты исключений из server.env (наследуются бот-клиентами).
: "${EXCLUDE_COUNTRIES:=}"
: "${EXCLUDE_ASNS:=}"
: "${EXCLUDE_CIDRS:=}"
: "${EXCLUDE_AGGREGATE:=0}"

NAME=""
CLIENT_DNS=""
CLIENT_MTU=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dns) CLIENT_DNS="${2//,/, }"; shift 2 ;;
    --mtu) CLIENT_MTU="$2"; shift 2 ;;
    --exclude-country) EXCLUDE_COUNTRIES="${EXCLUDE_COUNTRIES:+${EXCLUDE_COUNTRIES},}$2"; shift 2 ;;
    --exclude-asn)     EXCLUDE_ASNS="${EXCLUDE_ASNS:+${EXCLUDE_ASNS},}$2"; shift 2 ;;
    --exclude)         EXCLUDE_CIDRS="${EXCLUDE_CIDRS:+${EXCLUDE_CIDRS},}$2"; shift 2 ;;
    --aggregate)       EXCLUDE_AGGREGATE="$2"; shift 2 ;;
    -*)    die "Неизвестный аргумент: $1" ;;
    *)     [[ -z "${NAME}" ]] && NAME="$1" || die "Лишний аргумент: $1"; shift ;;
  esac
done
[[ -n "${NAME}" ]] || die "Укажи имя клиента: add_user.sh <имя> [--dns ...] [--mtu ...] [--exclude-* ...]"
validate_name "${NAME}"
: "${CLIENT_DNS:=${WG_DNS}}"
: "${CLIENT_MTU:=${WG_MTU}}"

CLIENT_DIR="${CLIENTS_DIR}/${NAME}"
[[ -d "${CLIENT_DIR}" ]] && die "Клиент '${NAME}' уже существует (${CLIENT_DIR})."

# ---------- Выбор свободного IP ----------
pick_ip() {
  local used octet
  # собираем занятые последние октеты из файлов клиентов
  used="$(cat "${CLIENTS_DIR}"/*/ip 2>/dev/null | awk -F. '{print $4}' | sort -n | tr '\n' ' ')"
  for octet in $(seq 2 254); do
    if ! grep -qw "${octet}" <<<"${used}"; then
      echo "${WG_SUBNET}.${octet}"
      return 0
    fi
  done
  die "Свободные адреса в подсети ${WG_SUBNET}.0/24 закончились."
}

CLIENT_IP="$(pick_ip)"
OCTET="${CLIENT_IP##*.}"
# IPv6-адрес клиента в той же позиции подсети (только если IPv6 включён на сервере).
CLIENT_IP6=""
[[ "${IPV6_ENABLED}" -eq 1 ]] && CLIENT_IP6="${WG_SUBNET6}::${OCTET}"

# ---------- Ключи клиента ----------
log "Создаю ключи для '${NAME}'…"
CLIENT_PRIV="$(awg genkey)"
CLIENT_PUB="$(echo "${CLIENT_PRIV}" | awg pubkey)"
CLIENT_PSK="$(awg genpsk)"

mkdir -p "${CLIENT_DIR}"; chmod 700 "${CLIENT_DIR}"
echo "${CLIENT_IP}"  > "${CLIENT_DIR}/ip"
echo "${CLIENT_PUB}" > "${CLIENT_DIR}/pubkey"
[[ -n "${CLIENT_IP6}" ]] && echo "${CLIENT_IP6}" > "${CLIENT_DIR}/ip6"

# ---------- Добавляем peer на сервер ----------
log "Регистрирую peer на сервере (${CLIENT_IP})…"
PEER_ALLOWED="${CLIENT_IP}/32"
[[ -n "${CLIENT_IP6}" ]] && PEER_ALLOWED="${PEER_ALLOWED}, ${CLIENT_IP6}/128"
cat >> "${WG_CONF}" <<EOF

[Peer]
# client: ${NAME}
PublicKey = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${PEER_ALLOWED}
EOF

# Применяем без разрыва текущих соединений
awg syncconf "${WG_IFACE}" <(awg-quick strip "${WG_IFACE}")

# ---------- Клиентский конфиг ----------
CLIENT_CONF="${CLIENT_DIR}/${NAME}.conf"
log "Формирую клиентский конфиг…"

# Адрес клиента (его собственный IP в туннеле) — не зависит от split-tunnel.
CLIENT_ADDR="${CLIENT_IP}/32"
[[ -n "${CLIENT_IP6}" ]] && CLIENT_ADDR="${CLIENT_ADDR}, ${CLIENT_IP6}/128"

# Маршруты В туннель (AllowedIPs). По умолчанию — весь трафик; со split-tunnel —
# весь МИНУС исключаемые сети (страны/ASN/CIDR), посчитанные lib/allowedips.py.
# IPv6 добавляем только если он включён на сервере (иначе ::/0 — чёрная дыра/утечка).
if [[ -n "${EXCLUDE_COUNTRIES}${EXCLUDE_ASNS}${EXCLUDE_CIDRS}" ]]; then
  need_cmd python3
  log "Считаю split-tunnel (страны='${EXCLUDE_COUNTRIES}' asn='${EXCLUDE_ASNS}' cidr='${EXCLUDE_CIDRS}' aggregate=${EXCLUDE_AGGREGATE})…"
  ai_out="$(python3 "${SCRIPT_DIR}/lib/allowedips.py" \
              --countries "${EXCLUDE_COUNTRIES}" --asns "${EXCLUDE_ASNS}" \
              --cidrs "${EXCLUDE_CIDRS}" --aggregate "${EXCLUDE_AGGREGATE}" \
              --ipv6 "${IPV6_ENABLED}")" \
    || die "Не удалось вычислить AllowedIPs (нет сети или RIPEstat недоступен). Создай без исключений или повтори позже."
  CLIENT_ALLOWED="$(printf '%s\n' "${ai_out}" | sed -n 's/^V4=//p')"
  ai_v6="$(printf '%s\n' "${ai_out}" | sed -n 's/^V6=//p')"
  [[ "${IPV6_ENABLED}" -eq 1 && -n "${ai_v6}" ]] && CLIENT_ALLOWED="${CLIENT_ALLOWED}, ${ai_v6}"
  [[ -n "${CLIENT_ALLOWED}" ]] || die "Пустой AllowedIPs после исключений — проверь параметры."
  log "split-tunnel: $(printf '%s' "${CLIENT_ALLOWED}" | awk -F, '{print NF}') диапазонов в туннель."
else
  CLIENT_ALLOWED="0.0.0.0/0"
  [[ -n "${CLIENT_IP6}" ]] && CLIENT_ALLOWED="${CLIENT_ALLOWED}, ::/0"
fi

{
  echo "[Interface]"
  echo "Address = ${CLIENT_ADDR}"
  echo "DNS = ${CLIENT_DNS}"
  echo "PrivateKey = ${CLIENT_PRIV}"
  echo "MTU = ${CLIENT_MTU}"
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
  echo ""
  echo "[Peer]"
  echo "PublicKey = ${SERVER_PUBKEY}"
  echo "PresharedKey = ${CLIENT_PSK}"
  echo "Endpoint = ${SERVER_IP}:${WG_PORT}"
  echo "AllowedIPs = ${CLIENT_ALLOWED}"
  echo "PersistentKeepalive = 25"
} > "${CLIENT_CONF}"
chmod 600 "${CLIENT_CONF}"

# ---------- QR-код ----------
# При split-tunnel AllowedIPs огромный → в QR не влезет. Делаем best-effort:
# если не вышло, просто нет .png (бот отправит только .conf).
CLIENT_QR="${CLIENT_DIR}/${NAME}.png"
if qrencode -t PNG -o "${CLIENT_QR}" < "${CLIENT_CONF}" 2>/dev/null; then
  qrencode -t ANSIUTF8 < "${CLIENT_CONF}" 2>/dev/null || true
else
  rm -f "${CLIENT_QR}"
  warn "Конфиг великоват для QR (split-tunnel) — используй файл .conf, без QR."
fi

log "Клиент '${NAME}' добавлен. IP ${CLIENT_IP}${CLIENT_IP6:+ / ${CLIENT_IP6}}"
echo "CONF=${CLIENT_CONF} QR=${CLIENT_QR}"
