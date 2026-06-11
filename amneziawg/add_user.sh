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
#   sudo ./add_user.sh <имя_клиента>
#
# Печатает в stdout строку:  CONF=<путь> QR=<путь>
# (бот парсит её, чтобы отправить файлы в Telegram).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root
load_server_env
need_cmd awg
need_cmd qrencode

NAME="${1:-}"
[[ -n "${NAME}" ]] || die "Укажи имя клиента: add_user.sh <имя>"
validate_name "${NAME}"

CLIENT_DIR="${CLIENTS_DIR}/${NAME}"
[[ -d "${CLIENT_DIR}" ]] && die "Клиент '${NAME}' уже существует (${CLIENT_DIR})."

# ---------- Выбор свободного IP ----------
pick_ip() {
  local used last octet
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

# ---------- Ключи клиента ----------
log "Создаю ключи для '${NAME}'…"
CLIENT_PRIV="$(awg genkey)"
CLIENT_PUB="$(echo "${CLIENT_PRIV}" | awg pubkey)"
CLIENT_PSK="$(awg genpsk)"

mkdir -p "${CLIENT_DIR}"; chmod 700 "${CLIENT_DIR}"
echo "${CLIENT_IP}"  > "${CLIENT_DIR}/ip"
echo "${CLIENT_PUB}" > "${CLIENT_DIR}/pubkey"

# ---------- Добавляем peer на сервер ----------
log "Регистрирую peer на сервере (${CLIENT_IP})…"
cat >> "${WG_CONF}" <<EOF

[Peer]
# client: ${NAME}
PublicKey = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF

# Применяем без разрыва текущих соединений
awg syncconf "${WG_IFACE}" <(awg-quick strip "${WG_IFACE}")

# ---------- Клиентский конфиг ----------
CLIENT_CONF="${CLIENT_DIR}/${NAME}.conf"
log "Формирую клиентский конфиг…"
cat > "${CLIENT_CONF}" <<EOF
[Interface]
Address = ${CLIENT_IP}/32
DNS = ${WG_DNS}
PrivateKey = ${CLIENT_PRIV}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_CONF}"

# ---------- QR-код ----------
CLIENT_QR="${CLIENT_DIR}/${NAME}.png"
qrencode -t PNG -o "${CLIENT_QR}" < "${CLIENT_CONF}"
# текстовый QR в консоль (удобно при ручном запуске)
qrencode -t ANSIUTF8 < "${CLIENT_CONF}" || true

log "Клиент '${NAME}' добавлен. IP ${CLIENT_IP}"
echo "CONF=${CLIENT_CONF} QR=${CLIENT_QR}"
