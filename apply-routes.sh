#!/bin/sh

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1" >&2
}

count_route_entries() {
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    { count++ }
    END {
      print count + 0
    }
  ' "$1"
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
IP_CMD_DEFAULT="/opt/sbin/ip"

if [ -f "$CONFIG" ]; then
  . "$CONFIG"
else
  failure "Failed to find file \"config\"."
fi

ROUTE_TABLE="${ROUTE_TABLE:-${TABLE_PRIMARY:-1000}}"
route_entries=0
IP_CMD="${IP_CMD:-$IP_CMD_DEFAULT}"

for _tool in awk mktemp rm; do
  command -v "$_tool" >/dev/null 2>&1 || \
  failure "\"${_tool}\" is required to run this script."
done

[ -x "$IP_CMD" ] || failure "\"${IP_CMD}\" is required to run this script."

BATCH_FILE="$(mktemp "${TMPDIR:-/tmp}/apply-routes.XXXXXX")" || \
failure "Failed to create a temporary batch file."

PIDFILE="${PIDFILE:-$PIDFILE_DEFAULT}"
[ -e "$PIDFILE" ] && failure "Found existing file \"${PIDFILE}\"."
( echo $$ > "$PIDFILE" ) 2>/dev/null || failure "Failed to create file \"${PIDFILE}\"."
trap 'rm -f "$PIDFILE" "$BATCH_FILE"' EXIT
trap 'exit 2' INT TERM QUIT HUP

[ -f "$FILE" ] || failure "File \"${FILE}\" does not exist."

if ! "$IP_CMD" address show dev "$IFACE" >/dev/null 2>&1; then
  failure "Failed to find interface \"${IFACE}\"."
elif [ -z "$("$IP_CMD" link show "${IFACE}" up 2>/dev/null)" ]; then
  failure "Interface \"${IFACE}\" is down."
fi

if "$IP_CMD" route flush table "$ROUTE_TABLE"; then
  log_info "Routing table #${ROUTE_TABLE} flushed."
else
  failure "Failed to flush routing table #${ROUTE_TABLE}."
fi

route_entries="$(count_route_entries "$FILE")"
log_info "Processing ${route_entries} route(s) from file \"${FILE}\"..."

while read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) continue ;;
  esac

  printf "route add table %s %s dev %s\n" "$ROUTE_TABLE" "$line" "$IFACE" >> "$BATCH_FILE" || \
  failure "Failed to prepare the batch file."
done < "$FILE"

"$IP_CMD" -batch "$BATCH_FILE" || failure "Failed to apply routes from the batch file."

log_info "Processing completed. #${ROUTE_TABLE}: $("$IP_CMD" route list table "$ROUTE_TABLE" | wc -l)."

exit 0
