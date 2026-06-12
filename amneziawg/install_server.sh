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
# Опции:
#   --port <n>      UDP-порт (по умолчанию 51820)
#   --subnet <a.b.c>  IPv4-подсеть /24 (по умолчанию 10.8.0)
#   --dns <list>    DNS для клиентов (по умолчанию 1.1.1.1, 1.0.0.1)
#   --mtu <n>       MTU интерфейса и клиентов (по умолчанию 1280; меньше из-за обфускации)
#   --ip <addr>     публичный IP/домен (иначе определяется автоматически)
#   --iface <name>  имя WG-интерфейса (по умолчанию awg0)
#   --subnet6 <p>   IPv6 ULA-префикс /64 (по умолчанию fd0a:1ce5:c0de)
#   --ipv6 <mode>   auto|on|off — туннелировать IPv6 (по умолчанию auto: если есть у сервера)
#   --legacy        старый формат обфускации AmneziaWG 1.x (для старых клиентов «Legacy»);
#                   по умолчанию генерируется формат AmneziaWG 2.0 (имитация протокола, CPS)
#
# Повторный запуск безопасен: если сервер уже настроен, ключи/параметры не перегенерируются.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------- Параметры по умолчанию ----------
WG_PORT="51820"
WG_SUBNET="10.8.0"       # /24 -> сервер .1, клиенты .2 ... .254
WG_DNS="1.1.1.1, 1.0.0.1"
WG_MTU="1280"            # ниже стандартных 1420: обфускация добавляет накладные расходы
WG_SUBNET6="fd0a:1ce5:c0de"  # IPv6 ULA /64 -> сервер ::1, клиенты ::2 ...
IPV6_MODE="auto"         # auto|on|off
AWG_MODE="v2"            # v2 (AmneziaWG 2.0) | legacy (старый формат 1.x, флаг --legacy)
LEGACY_FORCED=0          # был ли явно передан --legacy
AWG2_MIN_DATE="20250901" # минимальная версия amneziawg-tools с поддержкой формата 2.0
SERVER_IP=""             # публичный IP/домен; если пусто — определим автоматически

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    WG_PORT="$2"; shift 2 ;;
    --subnet)  WG_SUBNET="$2"; shift 2 ;;
    --dns)     WG_DNS="${2//,/, }"; shift 2 ;;
    --mtu)     WG_MTU="$2"; shift 2 ;;
    --subnet6) WG_SUBNET6="$2"; shift 2 ;;
    --ipv6)    IPV6_MODE="$2"; shift 2 ;;
    --legacy)  AWG_MODE="legacy"; LEGACY_FORCED=1; shift ;;
    --ip)      SERVER_IP="$2"; shift 2 ;;
    --iface)   WG_IFACE="$2"; WG_CONF="${WG_DIR}/${WG_IFACE}.conf"; shift 2 ;;
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

  # PPA Amnezia добавляем всегда (идемпотентно), затем ставим/ОБНОВЛЯЕМ до последней версии.
  # Важно: даже если awg уже стоит — тянем апгрейд, иначе старый 1.x-модуль не примет формат 2.0.
  if ! grep -rqs "amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    log "Добавляю PPA ppa:amnezia/ppa…"
    add-apt-repository -y ppa:amnezia/ppa
  fi
  apt-get update -y
  log "Ставлю/обновляю amneziawg + amneziawg-tools до последней версии (2.0)…"
  apt-get install -y amneziawg amneziawg-tools || apt-get install -y amneziawg

  need_cmd awg
  need_cmd awg-quick
  need_cmd qrencode
  log "Установлено: $(awg --version 2>/dev/null | head -n1)"
}

# Достаёт дату-версию YYYYMMDD из вывода `awg --version` (схема amneziawg-tools: 1.0.YYYYMMDD).
awg_version_date() {
  # || true: при отсутствии совпадения grep вернёт 1, иначе set -e уронил бы скрипт до проверки.
  awg --version 2>/dev/null | grep -oE '20[0-9]{6}' | head -n1 || true
}

# Гарантирует, что для формата 2.0 установлены tools >= AWG2_MIN_DATE. Иначе — падаем с инструкцией.
ensure_awg_version() {
  [[ "${AWG_MODE}" == "v2" ]] || return 0
  local d; d="$(awg_version_date)"
  if [[ -z "${d}" ]]; then
    warn "Не удалось прочитать версию AmneziaWG-tools из 'awg --version'."
    warn "Если служба не поднимется — обнови пакеты или переустанови с --legacy."
    return 0
  fi
  if [[ "${d}" -lt "${AWG2_MIN_DATE}" ]]; then
    err "AmneziaWG-tools версии ${d}, а для формата 2.0 нужна >= ${AWG2_MIN_DATE} (релиз 2.0)."
    err "Обнови до 2.0:"
    err "  sudo add-apt-repository ppa:amnezia/ppa && sudo apt-get update"
    err "  sudo apt-get install --only-upgrade -y amneziawg amneziawg-tools"
    die "…или переустанови в совместимом режиме 1.x:  sudo ./install_server.sh --legacy"
  fi
  log "AmneziaWG-tools ${d} — формат 2.0 поддерживается."
}

# Определяет итоговый AWG_MODE ДО записи состояния и проверки версии:
#  - существующий сервер -> формат берём из server.env (старый env без поля = legacy);
#  - свежая установка     -> значение из CLI (v2 по умолчанию, legacy при --legacy).
resolve_mode() {
  [[ -f "${SERVER_ENV}" ]] || return 0   # свежая установка: AWG_MODE уже из CLI
  local stored; stored="$(awk -F'"' '/^AWG_MODE=/{print $2; exit}' "${SERVER_ENV}" 2>/dev/null || true)"
  [[ -n "${stored}" ]] || stored="legacy"
  if [[ "${LEGACY_FORCED}" -eq 1 && "${stored}" != "legacy" ]]; then
    warn "Сервер уже установлен в формате '${stored}'. Смена формата требует пересоздания всех клиентов."
    warn "Для переустановки с нуля удали ${SERVER_ENV} и ${WG_CONF}, затем запусти снова."
  fi
  AWG_MODE="${stored}"
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

  # Есть ли у сервера глобальный IPv6 на внешнем интерфейсе?
  local has_v6=0
  if ip -6 addr show dev "${WAN_IFACE}" scope global 2>/dev/null | grep -q 'inet6'; then
    has_v6=1
  fi
  case "${IPV6_MODE}" in
    on)   IPV6_ENABLED=1 ;;
    off)  IPV6_ENABLED=0 ;;
    auto) IPV6_ENABLED="${has_v6}" ;;
    *)    die "--ipv6 принимает: auto | on | off" ;;
  esac
  if [[ "${IPV6_MODE}" == "on" && "${has_v6}" -eq 0 ]]; then
    warn "IPv6 включён принудительно, но глобального IPv6 на ${WAN_IFACE} нет — трафик ::/0 может не ходить."
  fi
  log "IPv6: $([[ "${IPV6_ENABLED}" -eq 1 ]] && echo 'включён' || echo 'выключен')"
}

# ---------- 3. Параметры обфускации AmneziaWG ----------
# Должны совпадать у сервера и всех клиентов. Генерируем по логике приложения Amnezia.
gen_obfuscation() {
  # H1..H4 — различные «магические» заголовки типов пакетов (нужны в обоих режимах).
  AWG_H1="$(rand_int 5 2000000000)"
  AWG_H2="$(rand_int 5 2000000000)"; while [[ "${AWG_H2}" == "${AWG_H1}" ]]; do AWG_H2="$(rand_int 5 2000000000)"; done
  AWG_H3="$(rand_int 5 2000000000)"; while [[ "${AWG_H3}" == "${AWG_H1}" || "${AWG_H3}" == "${AWG_H2}" ]]; do AWG_H3="$(rand_int 5 2000000000)"; done
  AWG_H4="$(rand_int 5 2000000000)"; while [[ "${AWG_H4}" == "${AWG_H1}" || "${AWG_H4}" == "${AWG_H2}" || "${AWG_H4}" == "${AWG_H3}" ]]; do AWG_H4="$(rand_int 5 2000000000)"; done

  AWG_S3=""; AWG_S4=""; AWG_I1=""   # есть только у 2.0; в legacy остаются пустыми

  if [[ "${AWG_MODE}" == "legacy" ]]; then
    # --- AmneziaWG 1.x (Legacy): шумовая обфускация, совместима со старыми клиентами ---
    AWG_JC="$(rand_int 4 12)"
    AWG_JMIN="$(rand_int 16 64)"
    AWG_JMAX="$(rand_int 512 1280)"
    AWG_S1="$(rand_int 15 150)"
    AWG_S2="$(rand_int 15 150)"
    while [[ $(( AWG_S1 + 56 )) -eq "${AWG_S2}" ]]; do AWG_S2="$(rand_int 15 150)"; done  # S1+56 != S2
  else
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
  fi
}

# ---------- 4. Состояние и ключи ----------
init_state() {
  mkdir -p "${STATE_DIR}" "${CLIENTS_DIR}" "${WG_DIR}"
  chmod 700 "${STATE_DIR}" "${CLIENTS_DIR}" "${WG_DIR}"

  if [[ -f "${SERVER_ENV}" ]]; then
    warn "Найден существующий ${SERVER_ENV} — повторно использую ключи и параметры обфускации."
    # shellcheck disable=SC1090
    source "${SERVER_ENV}"
    # Дефолты для значений, появившихся в новых версиях (старый server.env их не содержит).
    : "${WG_MTU:=1280}"
    : "${WG_SUBNET6:=fd0a:1ce5:c0de}"
    : "${IPV6_ENABLED:=0}"
    : "${AWG_MODE:=legacy}"   # старые установки были в формате 1.x
    : "${AWG_S3:=}"
    : "${AWG_S4:=}"
    : "${AWG_I1:=}"
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

  local addr="${WG_SUBNET}.1/24"
  [[ "${IPV6_ENABLED}" -eq 1 ]] && addr="${addr}, ${WG_SUBNET6}::1/64"

  {
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
    echo "# --- AmneziaWG: параметры обфускации ---"
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
  } > "${WG_CONF}"
  chmod 600 "${WG_CONF}"
}

# ---------- 6. Системные настройки ----------
enable_forwarding() {
  log "Включаю IP-форвардинг…"
  cat > /etc/sysctl.d/99-awg-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
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
  systemctl restart "awg-quick@${WG_IFACE}" || true
  systemctl --no-pager --full status "awg-quick@${WG_IFACE}" | head -n 5 || true

  if ! systemctl is-active --quiet "awg-quick@${WG_IFACE}"; then
    err "Служба awg-quick@${WG_IFACE} не запустилась. Логи: journalctl -u awg-quick@${WG_IFACE} -n 30"
    if [[ "${AWG_MODE}" != "legacy" ]]; then
      warn "Возможная причина: установленный модуль AmneziaWG старее 2.0 и не понимает формат 2.0 (I1/S3/S4)."
      warn "Переустанови сервер в совместимом режиме:  sudo ./install_server.sh --legacy  (или удали ${WG_CONF} и повтори)."
    fi
    die "Сервер не поднялся — см. сообщения выше."
  fi
}

# ---------- main ----------
install_packages
detect_network
resolve_mode          # формат: из server.env (если есть) или из CLI
ensure_awg_version    # гейт: для формата 2.0 нужны tools >= 2.0 (до записи состояния)
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
[[ "${IPV6_ENABLED}" -eq 1 ]] && echo "  IPv6      : ${WG_SUBNET6}::/64 (сервер ${WG_SUBNET6}::1)"
echo "  Обфускация: $([[ "${AWG_MODE}" == "legacy" ]] && echo 'AmneziaWG 1.x (Legacy)' || echo 'AmneziaWG 2.0 (имитация протокола)')"
echo "  MTU       : ${WG_MTU}"
echo "  Состояние : ${SERVER_ENV}"
echo
echo "Дальше: добавляй клиентов командой  sudo ./add_user.sh <имя>"
