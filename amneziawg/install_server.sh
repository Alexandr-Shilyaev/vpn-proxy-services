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
#   --awg3          формат обфускации AmneziaWG 3.1 (ПО УМОЛЧАНИЮ): к имитации протокола 2.0
#                   добавляются шифрование заголовков (HeaderProtectionKey), паддинг контента
#                   и рандомизированные тайминги. Нужны клиенты 3.1+ (см. README).
#   --awg2          формат AmneziaWG 2.0 (имитация протокола, CPS) — для клиентов 2.0
#   --legacy        старый формат AmneziaWG 1.x (для старых клиентов «Legacy»)
#
# Повторный запуск безопасен: если сервер уже настроен, ключи/параметры не перегенерируются.
# Сменить формат на уже работающем сервере: ./migrate.sh --to v3 (клиенты сохраняются).

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
AWG_MODE="v3"            # v3 (AmneziaWG 3.1) | v2 (2.0) | legacy (1.x)
MODE_FORCED=0            # был ли формат задан флагом явно
SERVER_IP=""             # публичный IP/домен; если пусто — определим автоматически

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    WG_PORT="$2"; shift 2 ;;
    --subnet)  WG_SUBNET="$2"; shift 2 ;;
    --dns)     WG_DNS="${2//,/, }"; shift 2 ;;
    --mtu)     WG_MTU="$2"; shift 2 ;;
    --subnet6) WG_SUBNET6="$2"; shift 2 ;;
    --ipv6)    IPV6_MODE="$2"; shift 2 ;;
    --awg3)    AWG_MODE="v3"; MODE_FORCED=1; shift ;;
    --awg2)    AWG_MODE="v2"; MODE_FORCED=1; shift ;;
    --legacy)  AWG_MODE="legacy"; MODE_FORCED=1; shift ;;
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

  # Базовые зависимости — должны установиться (иначе дальше идти нельзя):
  #   software-properties-common + python3-launchpadlib — для add-apt-repository (PPA);
  #   curl + ca-certificates — определение публичного IP по HTTPS;
  #   iproute2 — команда `ip` (на минимальных образах бывает не предустановлена);
  #   gnupg2, qrencode, iptables — ключи репозитория, QR, NAT.
  apt-get install -y software-properties-common python3-launchpadlib gnupg2 \
                     curl ca-certificates iproute2 qrencode iptables

  # Заголовки ядра для сборки модуля AmneziaWG (DKMS) — отдельно и best-effort:
  # их отсутствие не должно ронять установку базовых пакетов, но модуль тогда может не собраться.
  apt-get install -y "linux-headers-$(uname -r)" || \
    warn "Не удалось поставить linux-headers-$(uname -r) — модуль AmneziaWG может не собраться (нужен KVM-VPS)."

  # PPA Amnezia добавляем всегда (идемпотентно), затем ставим/ОБНОВЛЯЕМ до последней версии.
  # Важно: даже если awg уже стоит — тянем апгрейд, иначе старый 1.x-модуль не примет формат 2.0.
  if ! grep -rqs "amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    log "Добавляю PPA ppa:amnezia/ppa…"
    add-apt-repository -y ppa:amnezia/ppa
  fi
  apt-get update -y
  log "Ставлю/обновляю amneziawg + amneziawg-tools до последней версии (3.1)…"
  apt-get install -y amneziawg amneziawg-tools || apt-get install -y amneziawg

  need_cmd awg
  need_cmd awg-quick
  need_cmd qrencode
  log "Установлено: amneziawg-tools $(dpkg-query -W -f='${Version}' amneziawg-tools 2>/dev/null || echo '?')"
  log "Модуль (dkms): $(dpkg-query -W -f='${Version}' amneziawg-dkms 2>/dev/null || echo '?')"
}

# Определяет итоговый AWG_MODE ДО записи состояния и проверки версии:
#  - существующий сервер -> формат берём из server.env (старый env без поля = legacy);
#  - свежая установка     -> значение из CLI (v3 по умолчанию).
# Формат существующего сервера НЕ меняем: это сломало бы все выданные конфиги.
# Для смены формата есть migrate.sh, который заодно перевыпускает клиентов.
resolve_mode() {
  [[ -f "${SERVER_ENV}" ]] || return 0   # свежая установка: AWG_MODE уже из CLI
  local stored; stored="$(awk -F'"' '/^AWG_MODE=/{print $2; exit}' "${SERVER_ENV}" 2>/dev/null || true)"
  [[ -n "${stored}" ]] || stored="legacy"
  if [[ "${MODE_FORCED}" -eq 1 && "${stored}" != "${AWG_MODE}" ]]; then
    warn "Сервер уже установлен в формате '${stored}' — флаг формата игнорируется."
    warn "Сменить формат с сохранением клиентов:  sudo ./migrate.sh --to ${AWG_MODE}"
  elif [[ "${stored}" != "v3" ]]; then
    warn "Сервер работает в формате '${stored}'. Доступен более стойкий 3.1:"
    warn "  sudo ./migrate.sh --to v3   (клиенты сохраняются, конфиги перевыпускаются)"
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

# ---------- 3. Состояние и ключи ----------
init_state() {
  mkdir -p "${STATE_DIR}" "${CLIENTS_DIR}" "${WG_DIR}"
  chmod 700 "${STATE_DIR}" "${CLIENTS_DIR}" "${WG_DIR}"

  if [[ -f "${SERVER_ENV}" ]]; then
    warn "Найден существующий ${SERVER_ENV} — повторно использую ключи и параметры обфускации."
    # shellcheck disable=SC1090
    source "${SERVER_ENV}"
    awg_env_defaults   # поля, которых нет в server.env от старых версий
    return
  fi

  log "Генерирую ключи сервера и параметры обфускации…"
  SERVER_PRIVKEY="$(awg genkey)"
  SERVER_PUBKEY="$(echo "${SERVER_PRIVKEY}" | awg pubkey)"
  gen_obfuscation

  write_server_env
}

# ---------- 4. Серверный конфиг ----------
write_server_conf() {
  if [[ -f "${WG_CONF}" ]]; then
    warn "Конфиг ${WG_CONF} уже существует — не перезаписываю."
    return
  fi
  log "Создаю ${WG_CONF}…"
  render_server_iface > "${WG_CONF}"
  chmod 600 "${WG_CONF}"
}

# ---------- 5. Системные настройки ----------
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
    case "${AWG_MODE}" in
      v3)
        warn "Возможная причина: модуль/утилиты AmneziaWG старее 3.1 и не понимают параметры"
        warn "HeaderProtectionKey / RandomTrailers / диапазоны таймеров. Проверь версию модуля:"
        warn "  cat /sys/module/amneziawg/version ; dpkg-query -W amneziawg-dkms amneziawg-tools"
        warn "Откат на предыдущий формат: удали ${WG_CONF} и ${SERVER_ENV}, затем запусти с --awg2."
        ;;
      v2)
        warn "Возможная причина: установленный модуль AmneziaWG старее 2.0 и не понимает формат 2.0 (I1/S3/S4)."
        warn "Переустанови сервер в совместимом режиме:  sudo ./install_server.sh --legacy  (или удали ${WG_CONF} и повтори)."
        ;;
    esac
    die "Сервер не поднялся — см. сообщения выше."
  fi
}

# ---------- main ----------
install_packages
detect_network
resolve_mode          # формат: из server.env (если есть) или из CLI
ensure_awg_version    # гейт: tools/модуль должны понимать выбранный формат (до записи состояния)
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
echo "  Обфускация: $(awg_mode_label)"
echo "  MTU       : ${WG_MTU}"
echo "  Состояние : ${SERVER_ENV}"
echo
if [[ "${AWG_MODE}" == "v3" ]]; then
  echo "Формату 3.1 нужны клиенты: Amnezia VPN 5.0.1.5+, AmneziaWG для Windows 3.1.0+,"
  echo "AmneziaWG для Android 3.1+. Клиенты 2.0 к такому серверу не подключатся."
  echo
fi
echo "Дальше: добавляй клиентов командой  sudo ./add_user.sh <имя>"
