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
#   sudo ./add_user.sh <имя_клиента> [--dns 1.1.1.1,8.8.8.8] [--mtu 1280]
#
#   --dns <list>  переопределить DNS только для этого клиента (по умолчанию серверный)
#   --mtu <n>     переопределить MTU только для этого клиента (по умолчанию серверный)
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

NAME=""
CLIENT_DNS=""
CLIENT_MTU=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dns) CLIENT_DNS="${2//,/, }"; shift 2 ;;
    --mtu) CLIENT_MTU="$2"; shift 2 ;;
    -*)    die "Неизвестный аргумент: $1" ;;
    *)     [[ -z "${NAME}" ]] && NAME="$1" || die "Лишний аргумент: $1"; shift ;;
  esac
done
[[ -n "${NAME}" ]] || die "Укажи имя клиента: add_user.sh <имя> [--dns ...] [--mtu ...]"
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

# Адрес клиента и маршрутизируемые сети: IPv6 добавляем только если он включён на сервере,
# иначе ::/0 завернул бы IPv6 в туннель, где его некуда выпустить (чёрная дыра/утечка).
CLIENT_ADDR="${CLIENT_IP}/32"
CLIENT_ALLOWED="0.0.0.0/0"
if [[ -n "${CLIENT_IP6}" ]]; then
  CLIENT_ADDR="${CLIENT_ADDR}, ${CLIENT_IP6}/128"
  CLIENT_ALLOWED="${CLIENT_ALLOWED}, ::/0"
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
CLIENT_QR="${CLIENT_DIR}/${NAME}.png"
qrencode -t PNG -o "${CLIENT_QR}" < "${CLIENT_CONF}"
# текстовый QR в консоль (удобно при ручном запуске)
qrencode -t ANSIUTF8 < "${CLIENT_CONF}" || true

log "Клиент '${NAME}' добавлен. IP ${CLIENT_IP}${CLIENT_IP6:+ / ${CLIENT_IP6}}"
echo "CONF=${CLIENT_CONF} QR=${CLIENT_QR}"
