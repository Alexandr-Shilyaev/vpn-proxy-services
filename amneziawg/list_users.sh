#!/usr/bin/env bash
# list_users.sh — список клиентов AmneziaWG (имя, IP, статус последнего хендшейка).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root
load_server_env

shopt -s nullglob
found=0
for dir in "${CLIENTS_DIR}"/*/; do
  found=1
  name="$(basename "${dir}")"
  ip="$(cat "${dir}/ip" 2>/dev/null || echo '?')"
  pub="$(cat "${dir}/pubkey" 2>/dev/null || echo '')"
  hs="$(awg show "${WG_IFACE}" latest-handshakes 2>/dev/null | awk -v p="${pub}" '$1==p{print $2}')"
  if [[ -n "${hs}" && "${hs}" != "0" ]]; then
    status="last handshake $(( ($(date +%s) - hs) / 60 )) мин назад"
  else
    status="нет соединений"
  fi
  printf '%-20s %-14s %s\n' "${name}" "${ip}" "${status}"
done
[[ "${found}" -eq 0 ]] && echo "Клиентов пока нет."
