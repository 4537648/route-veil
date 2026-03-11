#!/bin/sh

add_ip() {
  ip route add table "$ROUTE_TABLE" "$1" dev "$IFACE" 2>/dev/null
}

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1" >&2
}

check_ip() {
  # https://stackoverflow.com/a/36760050
  if echo "$1" | grep -qP \
  '^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])(\.(?!$)|(\/(3[0-2]|[12][0-9]|[0-9]))?$)){4}$'; then
    return 0
  else
    return 1
  fi
}

log_info() {
  msg "$1"
  logger -t "route-veil/apply-routes" "$1"
}

log_error() {
  error_msg "$1"
  logger -t "route-veil/apply-routes" "Error: $1"
}

failure() {
  log_error "$1"
  exit 1
}

INSTALL_DIR="/opt/etc/route-veil"
CONFIG="${INSTALL_DIR}/config"
PIDFILE_DEFAULT="/tmp/apply-routes.sh.pid"

if [ -f "$CONFIG" ]; then
  . "$CONFIG"
else
  failure "Failed to find file \"config\"."
fi

ROUTE_TABLE="${ROUTE_TABLE:-${TABLE_PRIMARY:-1000}}"
invalid_entries=0

for _tool in grep ip rm; do
  command -v "$_tool" >/dev/null 2>&1 || \
  failure "\"${_tool}\" is required to run this script."
done

PIDFILE="${PIDFILE:-$PIDFILE_DEFAULT}"
[ -e "$PIDFILE" ] && failure "Found existing file \"${PIDFILE}\"."
( echo $$ > "$PIDFILE" ) 2>/dev/null || failure "Failed to create file \"${PIDFILE}\"."
trap 'rm -f "$PIDFILE"' EXIT
trap 'exit 2' INT TERM QUIT HUP

[ -f "$FILE" ] || failure "File \"${FILE}\" does not exist."

if ! ip address show dev "$IFACE" >/dev/null 2>&1; then
  failure "Failed to find interface \"${IFACE}\"."
elif [ -z "$(ip link show "${IFACE}" up 2>/dev/null)" ]; then
  failure "Interface \"${IFACE}\" is down."
fi

if ip route flush table "$ROUTE_TABLE"; then
  log_info "Routing table #${ROUTE_TABLE} flushed."
else
  failure "Failed to flush routing table #${ROUTE_TABLE}."
fi

log_info "Processing $(grep -c "" "$FILE") line(s) from file \"${FILE}\"..."

while read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) continue ;;
  esac

  if check_ip "$line"; then
    add_ip "$line"
  else
    invalid_entries=$((invalid_entries + 1))
  fi
done < "$FILE"

if [ "$invalid_entries" -gt 0 ]; then
  log_info "Skipped ${invalid_entries} invalid non-IP/CIDR entr$( [ "$invalid_entries" -eq 1 ] && printf "y" || printf "ies" )."
fi

log_info "Processing completed. #${ROUTE_TABLE}: $(ip route list table "$ROUTE_TABLE" | wc -l)."

exit 0
