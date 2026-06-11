#!/usr/bin/env bash
# del_user.sh — (в) удалить клиента AmneziaWG.
#
# Делает:
#   - снимает peer с работающего интерфейса (awg set ... remove);
#   - вырезает блок [Peer] клиента из серверного конфига;
#   - удаляет каталог клиента с ключами/конфигом/QR.
#
# Использование:
#   sudo ./del_user.sh <имя_клиента>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root
load_server_env
need_cmd awg

NAME="${1:-}"
[[ -n "${NAME}" ]] || die "Укажи имя клиента: del_user.sh <имя>"
validate_name "${NAME}"

CLIENT_DIR="${CLIENTS_DIR}/${NAME}"
[[ -d "${CLIENT_DIR}" ]] || die "Клиент '${NAME}' не найден."

PUB="$(cat "${CLIENT_DIR}/pubkey" 2>/dev/null || true)"
[[ -n "${PUB}" ]] || die "Не найден публичный ключ клиента '${NAME}'."

# ---------- Снять peer с живого интерфейса ----------
log "Удаляю peer с интерфейса ${WG_IFACE}…"
awg set "${WG_IFACE}" peer "${PUB}" remove 2>/dev/null || warn "Peer не был активен на интерфейсе."

# ---------- Вырезать [Peer] из конфига ----------
log "Чищу ${WG_CONF}…"
tmp="$(mktemp)"
# Режим абзацев (RS=""): каждый [Interface]/[Peer] блок — отдельная запись.
# Печатаем все записи, КРОМЕ той, что содержит публичный ключ клиента.
awk -v pub="${PUB}" 'BEGIN{RS="";ORS="\n\n"} index($0, pub)==0 {print}' "${WG_CONF}" > "${tmp}"
install -m 600 "${tmp}" "${WG_CONF}"
rm -f "${tmp}"

# Применяем на лету (на случай рассинхрона)
awg syncconf "${WG_IFACE}" <(awg-quick strip "${WG_IFACE}") 2>/dev/null || true

# ---------- Удалить файлы клиента ----------
rm -rf "${CLIENT_DIR}"

log "Клиент '${NAME}' удалён."
echo "DELETED=${NAME}"
