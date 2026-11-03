#!/usr/bin/env bash
# migrate.sh — смена формата обфускации AmneziaWG на уже работающем сервере.
#
# Зачем отдельный скрипт: обновить формат «на месте» нельзя — у 3.1 другой набор
# параметров (HeaderProtectionKey, диапазоны таймеров, RandomTrailers), и они должны
# совпадать у сервера и у КАЖДОГО клиента. Поэтому нужен новый набор параметров и
# перевыпуск всех клиентских конфигов.
#
# Что сохраняется: ключи клиентов, их IP-адреса и peer'ы на сервере — то есть
# список пользователей не теряется, пересобираются только файлы .conf и QR.
# Что меняется: блок обфускации у сервера и у всех клиентов.
#
# Использование:
#   sudo ./migrate.sh --to v3        # 1.x/2.0 -> 3.1 (рекомендуется)
#   sudo ./migrate.sh --to v2        # вернуться на 2.0 (например, старые клиенты)
#   sudo ./migrate.sh --to legacy    # вернуться на 1.x
#   sudo ./migrate.sh --regen        # заново сгенерировать параметры текущего формата
#
# Опции:
#   --to <v3|v2|legacy>  целевой формат обфускации
#   --regen              перегенерировать параметры, не меняя формат
#   --yes                не спрашивать подтверждение
#   --iface <name>       имя WG-интерфейса (по умолчанию awg0)
#
# ⚠️ После миграции клиентам НУЖНО заново отправить .conf/QR: старые не подключатся.
#    Через бота это кнопка «добавить» не нужна — файлы уже обновлены в
#    /etc/awg-vpn/clients/<имя>/, их достаточно переслать заново.
#
# Если служба не поднимется с новым форматом, скрипт сам откатит всё из бэкапа.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TARGET=""
REGEN=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)      TARGET="$2"; shift 2 ;;
    --regen)   REGEN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --iface)   WG_IFACE="$2"; WG_CONF="${WG_DIR}/${WG_IFACE}.conf"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

need_root
need_cmd awg
need_cmd awg-quick
need_cmd qrencode
load_server_env
awg_env_defaults

CURRENT_MODE="${AWG_MODE}"
[[ -f "${WG_CONF}" ]] || die "Нет серверного конфига ${WG_CONF}. Сначала install_server.sh"

# ---------- Разбор цели ----------
if [[ -z "${TARGET}" ]]; then
  [[ "${REGEN}" -eq 1 ]] || die "Укажи целевой формат: --to v3 | v2 | legacy  (или --regen)"
  TARGET="${CURRENT_MODE}"
fi
case "${TARGET}" in
  v3|v2|legacy) ;;
  *) die "--to принимает: v3 | v2 | legacy" ;;
esac
if [[ "${TARGET}" == "${CURRENT_MODE}" && "${REGEN}" -eq 0 ]]; then
  log "Сервер уже в формате '${CURRENT_MODE}' ($(awg_mode_label "${CURRENT_MODE}")) — делать нечего."
  log "Если нужно просто сменить сами значения параметров: sudo ./migrate.sh --regen"
  exit 0
fi

# Гейт версий: модуль/утилиты должны понимать целевой формат. Делаем ДО бэкапа и правок.
ensure_awg_version "${TARGET}"

# ---------- Подтверждение ----------
CLIENT_NAMES=()
while IFS= read -r d; do
  [[ -n "${d}" ]] && CLIENT_NAMES+=("$(basename "${d}")")
done < <(find "${CLIENTS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
echo
echo "  Интерфейс     : ${WG_IFACE}"
echo "  Текущий формат: $(awg_mode_label "${CURRENT_MODE}")"
echo "  Новый формат  : $(awg_mode_label "${TARGET}")"
echo "  Клиентов      : ${#CLIENT_NAMES[@]}${CLIENT_NAMES[*]:+ (${CLIENT_NAMES[*]})}"
echo
warn "Всем клиентам придётся заново раздать .conf/QR — старые перестанут подключаться."
if [[ "${TARGET}" == "v3" ]]; then
  warn "Формату 3.1 нужны: Amnezia VPN 5.0.1.5+, AmneziaWG Windows 3.1.0+, Android 3.1+."
fi
if [[ "${ASSUME_YES}" -eq 0 ]]; then
  ans=""; read -rp "Продолжить? [y/N] " ans || true
  [[ "${ans}" =~ ^[Yy]$ ]] || die "Отменено."
fi

# [Interface] пересобирается из server.env, поэтому правки, сделанные только в awg0.conf
# (например, смена порта вручную), потерялись бы. Сверяем и предупреждаем заранее.
LIVE_PORT="$(get_conf_value "${WG_CONF}" ListenPort)"
if [[ -n "${LIVE_PORT}" && "${LIVE_PORT}" != "${WG_PORT}" ]]; then
  warn "В ${WG_CONF} порт ${LIVE_PORT}, а в ${SERVER_ENV} — ${WG_PORT}."
  warn "Будет использован порт из server.env (${WG_PORT}). Если верен ${LIVE_PORT}, прерви"
  warn "миграцию (Ctrl+C), поправь WG_PORT в ${SERVER_ENV} и запусти снова."
  if [[ "${ASSUME_YES}" -eq 0 ]]; then
    ans=""; read -rp "Продолжить с портом ${WG_PORT}? [y/N] " ans || true
    [[ "${ans}" =~ ^[Yy]$ ]] || die "Отменено."
  fi
fi

# ---------- Бэкап ----------
BACKUP_DIR="${STATE_DIR}/backup/$(date -u +%Y%m%d-%H%M%S)-${CURRENT_MODE}"
mkdir -p "${BACKUP_DIR}"
chmod 700 "${STATE_DIR}/backup" "${BACKUP_DIR}"
cp -a "${SERVER_ENV}" "${BACKUP_DIR}/server.env"
cp -a "${WG_CONF}"    "${BACKUP_DIR}/$(basename "${WG_CONF}")"
[[ -d "${CLIENTS_DIR}" ]] && cp -a "${CLIENTS_DIR}" "${BACKUP_DIR}/clients"
log "Бэкап: ${BACKUP_DIR}"

rollback() {
  err "Откатываю изменения из бэкапа…"
  cp -a "${BACKUP_DIR}/server.env" "${SERVER_ENV}"
  cp -a "${BACKUP_DIR}/$(basename "${WG_CONF}")" "${WG_CONF}"
  if [[ -d "${BACKUP_DIR}/clients" ]]; then
    rm -rf "${CLIENTS_DIR}"
    cp -a "${BACKUP_DIR}/clients" "${CLIENTS_DIR}"
  fi
  systemctl restart "awg-quick@${WG_IFACE}" || true
  err "Откат выполнен: сервер снова в формате ${CURRENT_MODE}. Старые конфиги клиентов действительны."
}

# ---------- Новые параметры обфускации ----------
log "Генерирую параметры формата ${TARGET}…"
AWG_MODE="${TARGET}"
gen_obfuscation
write_server_env

# ---------- Серверный конфиг: новый [Interface] + прежние [Peer] ----------

log "Перезаписываю ${WG_CONF} (peer'ы сохраняются)…"
PEERS="$(awk '/^\[Peer\]/{found=1} found' "${WG_CONF}")"
TMP_CONF="$(mktemp "${WG_CONF}.XXXXXX")"
render_server_iface > "${TMP_CONF}"
if [[ -n "${PEERS}" ]]; then
  printf '\n%s\n' "${PEERS}" >> "${TMP_CONF}"
fi
chmod 600 "${TMP_CONF}"
mv "${TMP_CONF}" "${WG_CONF}"

# ---------- Клиентские конфиги ----------
if [[ "${#CLIENT_NAMES[@]}" -gt 0 ]]; then
  log "Перевыпускаю клиентские конфиги и QR…"
  DONE_N=0
  for name in "${CLIENT_NAMES[@]}"; do
    regen_client_conf "${name}" && DONE_N=$(( DONE_N + 1 ))
  done
  log "Перевыпущено конфигов: ${DONE_N} из ${#CLIENT_NAMES[@]}"
fi

# ---------- Перезапуск ----------
# Именно restart, а не syncconf: меняются параметры уровня устройства, и часть из них
# (см. amneziawg #207) нельзя снять через `awg setconf` на живом интерфейсе.
log "Перезапускаю awg-quick@${WG_IFACE}…"
if ! systemctl restart "awg-quick@${WG_IFACE}"; then
  err "Служба не перезапустилась."
  rollback
  die "Миграция отменена. Логи: journalctl -u awg-quick@${WG_IFACE} -n 30"
fi
if ! systemctl is-active --quiet "awg-quick@${WG_IFACE}"; then
  err "Служба неактивна после перезапуска."
  if [[ "${TARGET}" == "v3" ]]; then
    err "Вероятно, модуль AmneziaWG не понимает параметры 3.1. Проверь:"
    err "  cat /sys/module/amneziawg/version ; dpkg-query -W amneziawg-dkms amneziawg-tools"
  fi
  rollback
  die "Миграция отменена. Логи: journalctl -u awg-quick@${WG_IFACE} -n 30"
fi

echo
log "Готово. Формат обфускации: $(awg_mode_label "${TARGET}")"
echo "  Бэкап старого состояния : ${BACKUP_DIR}"
echo "  Клиентские файлы        : ${CLIENTS_DIR}/<имя>/<имя>.conf (+ .png)"
echo
echo "⚠️  Раздай клиентам новые .conf/QR — старые больше не подключатся."
[[ "${TARGET}" == "v3" ]] && echo "    Нужны клиенты: Amnezia VPN 5.0.1.5+, AmneziaWG Windows 3.1.0+, Android 3.1+."
exit 0
