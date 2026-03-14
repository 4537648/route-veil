#!/bin/sh

INSTALL_DIR="/opt/etc/route-veil"
CONFIG="${INSTALL_DIR}/config"
APPLY_ROUTES="${INSTALL_DIR}/apply-routes.sh"
RULE_PRIORITY="1995"
PIDFILE_DEFAULT="/tmp/apply-routes.sh.pid"
[ -f "$CONFIG" ] || exit 0
. "$CONFIG"

TABLE_PRIMARY="${TABLE_PRIMARY:-1000}"
TABLE_SECONDARY="${TABLE_SECONDARY:-1001}"
ACTIVE_TABLE_FILE="${ACTIVE_TABLE_FILE:-/opt/etc/route-veil/active-table}"
RULE_IIF_LIST="${RULE_IIF_LIST-br0}"

log_info() {
  logger -t "route-veil/hook" "$1"
}

log_error() {
  logger -t "route-veil/hook" "Error: $1"
}

active_table_read() {
  if [ -f "$ACTIVE_TABLE_FILE" ]; then
    sed -n '1p' "$ACTIVE_TABLE_FILE"
  else
    printf "%s\n" "$TABLE_PRIMARY"
  fi
}

rule_desc() {
  if [ -n "$RULE_IIF_LIST" ]; then
    printf "%s\n" "$(printf "%s" "$RULE_IIF_LIST" | tr ' ' ',') -> table $1"
  else
    printf "%s\n" "all traffic -> table $1"
  fi
}

rules_add() {
  failed=0
  if [ -n "$RULE_IIF_LIST" ]; then
    for iface in $RULE_IIF_LIST; do
      if ! ip rule add iif "$iface" table "$1" priority "$RULE_PRIORITY" 2>/dev/null; then
        log_error "Failed to enable policy rule for interface \"${iface}\" in table ${1}."
        failed=1
      fi
    done
  else
    if ! ip rule add table "$1" priority "$RULE_PRIORITY" 2>/dev/null; then
      log_error "Failed to enable policy rule for table ${1}."
      failed=1
    fi
  fi
  return "$failed"
}

rules_delete() {
  if [ -n "$RULE_IIF_LIST" ]; then
    for iface in $RULE_IIF_LIST; do
      ip rule del iif "$iface" table "$1" priority "$RULE_PRIORITY" 2>/dev/null || true
    done
  else
    ip rule del table "$1" priority "$RULE_PRIORITY" 2>/dev/null || true
  fi
}

# https://github.com/ndmsystems/packages/wiki/Opkg-Component
[ "$1" != "hook" ] && exit 0
[ "$system_name" != "$IFACE" ] && exit 0

kill_apply_routes() {
  PIDFILE="${PIDFILE:-$PIDFILE_DEFAULT}"
  if [ -e "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE")"
    if [ -n "$PID" ] && [ -d "/proc/${PID}" ]; then
      kill "$PID"
    else
      rm -f "$PIDFILE"
    fi
  fi
}

case ${connected}-${link}-${up} in
  yes-up-up)
    ACTIVE_TABLE="$(active_table_read)"
    if rules_add "$ACTIVE_TABLE"; then
      log_info "Tunnel interface \"${IFACE}\" is up. Policy rules enabled for $(rule_desc "$ACTIVE_TABLE")."
      if [ -z "$(ip route list table "$ACTIVE_TABLE" 2>/dev/null)" ]; then
        ROUTE_TABLE="$ACTIVE_TABLE" "$APPLY_ROUTES" &
        log_info "Active table ${ACTIVE_TABLE} is empty. apply-routes.sh started."
      else
        log_info "Active table ${ACTIVE_TABLE} already populated. apply-routes.sh skipped."
      fi
    else
      log_error "Failed to enable policy rules for $(rule_desc "$ACTIVE_TABLE")."
    fi
  ;;
  no-down-*)
    ACTIVE_TABLE="$(active_table_read)"
    kill_apply_routes
    rules_delete "$ACTIVE_TABLE"
    log_info "Tunnel interface \"${IFACE}\" is down. Policy rules disabled for $(rule_desc "$ACTIVE_TABLE")."
  ;;
esac

exit 0
