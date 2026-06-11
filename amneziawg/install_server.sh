#!/usr/bin/env bash
# install_server.sh — (а) установка AmneziaWG и базовая настройка сервера.
#
# Делает:
#   - ставит пакеты и amneziawg из официального PPA;
#   - генерирует ключи сервера и параметры обфускации AmneziaWG;
#   - создаёт серверный конфиг awg0.conf;
#   - включает IP-форвардинг и NAT (iptables) на внешнем интерфейсе;
#   - запускает службу awg-quick@awg0 и сохраняет состояние в /etc/awg-vpn.
#
# Использование:
#   sudo ./install_server.sh [--port 51820] [--subnet 10.8.0] [--dns 1.1.1.1,8.8.8.8]
#
# Повторный запуск безопасен: если сервер уже настроен, ключи/параметры не перегенерируются.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------- Параметры по умолчанию ----------
WG_PORT="51820"
WG_SUBNET="10.8.0"       # /24 -> сервер .1, клиенты .2 ... .254
WG_DNS="1.1.1.1, 1.0.0.1"
SERVER_IP=""             # публичный IP/домен; если пусто — определим автоматически

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)   WG_PORT="$2"; shift 2 ;;
    --subnet) WG_SUBNET="$2"; shift 2 ;;
    --dns)    WG_DNS="${2//,/, }"; shift 2 ;;
    --ip)     SERVER_IP="$2"; shift 2 ;;
    --iface)  WG_IFACE="$2"; WG_CONF="${WG_DIR}/${WG_IFACE}.conf"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

need_root

# ---------- 1. Установка пакетов ----------
install_packages() {
  log "Устанавливаю зависимости и AmneziaWG…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y software-properties-common python3-launchpadlib \
                     gnupg2 curl qrencode iptables "linux-headers-$(uname -r)" || \
    apt-get install -y software-properties-common gnupg2 curl qrencode iptables

  if ! command -v awg >/dev/null 2>&1; then
    log "Добавляю PPA ppa:amnezia/ppa…"
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update -y
    apt-get install -y amneziawg amneziawg-tools || apt-get install -y amneziawg
  else
    log "AmneziaWG уже установлен ($(awg --version 2>/dev/null | head -n1))"
  fi

  need_cmd awg
  need_cmd awg-quick
  need_cmd qrencode
}

# ---------- 2. Внешний IP и интерфейс ----------
detect_network() {
  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
    [[ -n "${SERVER_IP}" ]] || die "Не удалось определить публичный IP. Передай его через --ip"
  fi
  WAN_IFACE="$(ip -4 route ls default | awk '{print $5; exit}')"
  [[ -n "${WAN_IFACE}" ]] || die "Не удалось определить внешний сетевой интерфейс."
  log "Публичный адрес: ${SERVER_IP} | внешний интерфейс: ${WAN_IFACE}"
}

# ---------- 3. Параметры обфускации AmneziaWG ----------
# Должны совпадать у сервера и всех клиентов. Генерируем по логике приложения Amnezia.
gen_obfuscation() {
  AWG_JC="$(rand_int 4 12)"     # кол-во junk-пакетов
  AWG_JMIN="50"
  AWG_JMAX="1000"
  AWG_S1="$(rand_int 15 150)"
  AWG_S2="$(rand_int 15 150)"
  # ограничение Amnezia: S1 + 56 != S2
  while [[ $(( AWG_S1 + 56 )) -eq "${AWG_S2}" ]]; do AWG_S2="$(rand_int 15 150)"; done
  # H1..H4 — различные «магические» заголовки
  AWG_H1="$(rand_int 5 2000000000)"
  AWG_H2="$(rand_int 5 2000000000)"; while [[ "${AWG_H2}" == "${AWG_H1}" ]]; do AWG_H2="$(rand_int 5 2000000000)"; done
  AWG_H3="$(rand_int 5 2000000000)"; while [[ "${AWG_H3}" == "${AWG_H1}" || "${AWG_H3}" == "${AWG_H2}" ]]; do AWG_H3="$(rand_int 5 2000000000)"; done
  AWG_H4="$(rand_int 5 2000000000)"; while [[ "${AWG_H4}" == "${AWG_H1}" || "${AWG_H4}" == "${AWG_H2}" || "${AWG_H4}" == "${AWG_H3}" ]]; do AWG_H4="$(rand_int 5 2000000000)"; done
}

# ---------- 4. Состояние и ключи ----------
init_state() {
  mkdir -p "${STATE_DIR}" "${CLIENTS_DIR}" "${WG_DIR}"
  chmod 700 "${STATE_DIR}" "${CLIENTS_DIR}" "${WG_DIR}"

  if [[ -f "${SERVER_ENV}" ]]; then
    warn "Найден существующий ${SERVER_ENV} — повторно использую ключи и параметры обфускации."
    # shellcheck disable=SC1090
    source "${SERVER_ENV}"
    return
  fi

  log "Генерирую ключи сервера и параметры обфускации…"
  SERVER_PRIVKEY="$(awg genkey)"
  SERVER_PUBKEY="$(echo "${SERVER_PRIVKEY}" | awg pubkey)"
  gen_obfuscation

  cat > "${SERVER_ENV}" <<EOF
# Состояние сервера AmneziaWG. Создано install_server.sh $(date -u +%FT%TZ)
SERVER_IP="${SERVER_IP}"
WAN_IFACE="${WAN_IFACE}"
WG_IFACE="${WG_IFACE}"
WG_PORT="${WG_PORT}"
WG_SUBNET="${WG_SUBNET}"
WG_DNS="${WG_DNS}"
SERVER_PRIVKEY="${SERVER_PRIVKEY}"
SERVER_PUBKEY="${SERVER_PUBKEY}"
# --- параметры обфускации (одинаковые у сервера и клиентов) ---
AWG_JC="${AWG_JC}"
AWG_JMIN="${AWG_JMIN}"
AWG_JMAX="${AWG_JMAX}"
AWG_S1="${AWG_S1}"
AWG_S2="${AWG_S2}"
AWG_H1="${AWG_H1}"
AWG_H2="${AWG_H2}"
AWG_H3="${AWG_H3}"
AWG_H4="${AWG_H4}"
EOF
  chmod 600 "${SERVER_ENV}"
}

# ---------- 5. Серверный конфиг ----------
write_server_conf() {
  if [[ -f "${WG_CONF}" ]]; then
    warn "Конфиг ${WG_CONF} уже существует — не перезаписываю."
    return
  fi
  log "Создаю ${WG_CONF}…"
  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_SUBNET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVKEY}
# NAT и форвардинг включаются при старте/остановке интерфейса
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_SUBNET}.0/24 -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_SUBNET}.0/24 -o ${WAN_IFACE} -j MASQUERADE

# --- AmneziaWG: параметры обфускации ---
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF
  chmod 600 "${WG_CONF}"
}

# ---------- 6. Системные настройки ----------
enable_forwarding() {
  log "Включаю IP-форвардинг…"
  cat > /etc/sysctl.d/99-awg-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null
}

open_firewall() {
  # Открываем UDP-порт, если активен ufw
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    log "Открываю UDP/${WG_PORT} в ufw…"
    ufw allow "${WG_PORT}/udp" >/dev/null || true
  fi
}

start_service() {
  log "Запускаю службу awg-quick@${WG_IFACE}…"
  systemctl enable "awg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
  # перезапуск, чтобы подхватить свежий конфиг
  systemctl restart "awg-quick@${WG_IFACE}"
  systemctl --no-pager --full status "awg-quick@${WG_IFACE}" | head -n 5 || true
}

# ---------- main ----------
install_packages
detect_network
init_state
write_server_conf
enable_forwarding
open_firewall
start_service

log "Готово. Сервер AmneziaWG поднят."
echo
echo "  Интерфейс : ${WG_IFACE}"
echo "  Endpoint  : ${SERVER_IP}:${WG_PORT}"
echo "  Подсеть   : ${WG_SUBNET}.0/24 (сервер ${WG_SUBNET}.1)"
echo "  Состояние : ${SERVER_ENV}"
echo
echo "Дальше: добавляй клиентов командой  sudo ./add_user.sh <имя>"
