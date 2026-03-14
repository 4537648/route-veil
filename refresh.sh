#!/bin/sh

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1" >&2
}

log_info() {
  logger -t "route-veil/refresh" "$1"
}

log_error() {
  logger -t "route-veil/refresh" "Error: $1"
}

INSTALL_DIR="/opt/etc/route-veil"
BUILDER="${INSTALL_DIR}/builder.sh"
APPLY_ROUTES="${INSTALL_DIR}/apply-routes.sh"
CONFIG="${INSTALL_DIR}/config"
RULE_PRIORITY="1995"

rule_desc() {
  if [ -n "$RULE_IIF_LIST" ]; then
    printf "%s\n" "$(printf "%s" "$RULE_IIF_LIST" | tr ' ' ',') -> table $1"
  else
    printf "%s\n" "all traffic -> table $1"
  fi
}

active_table_read() {
  if [ -f "$ACTIVE_TABLE_FILE" ]; then
    sed -n '1p' "$ACTIVE_TABLE_FILE"
  else
    printf "%s\n" "$TABLE_PRIMARY"
  fi
}

active_table_exists() {
  [ -f "$ACTIVE_TABLE_FILE" ]
}

active_table_write() {
  printf "%s\n" "$1" > "$ACTIVE_TABLE_FILE"
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

table_flush() {
  ip route flush table "$1" >/dev/null 2>&1
}

for _file in "$BUILDER" "$APPLY_ROUTES"; do
  [ -x "$_file" ] || {
    error_msg "\"${_file}\" is required to refresh routes."
    log_error "\"${_file}\" is required to refresh routes."
    exit 1
  }
done

[ -f "$CONFIG" ] || {
  error_msg "\"${CONFIG}\" is required to refresh routes."
  log_error "\"${CONFIG}\" is required to refresh routes."
  exit 1
}

. "$CONFIG"

RULE_IIF_LIST="${RULE_IIF_LIST-br0}"
TABLE_PRIMARY="${TABLE_PRIMARY:-1000}"
TABLE_SECONDARY="${TABLE_SECONDARY:-1001}"
ACTIVE_TABLE_FILE="${ACTIVE_TABLE_FILE:-${INSTALL_DIR}/active-table}"

command -v ip >/dev/null 2>&1 || {
  error_msg "\"ip\" is required to refresh routes."
  log_error "\"ip\" is required to refresh routes."
  exit 1
}

if ! ip address show dev "$IFACE" >/dev/null 2>&1; then
  error_msg "Failed to find interface \"${IFACE}\"."
  log_error "Failed to find interface \"${IFACE}\"."
  exit 1
elif [ -z "$(ip link show "$IFACE" up 2>/dev/null)" ]; then
  error_msg "Interface \"${IFACE}\" is down."
  log_error "Interface \"${IFACE}\" is down."
  exit 1
fi

log_info "Daily refresh started."
msg "Refreshing route list and routing table..."

ACTIVE_TABLE="$(active_table_read)"
if active_table_exists; then
  ACTIVE_TABLE_WAS_SET="1"
  if [ "$ACTIVE_TABLE" = "$TABLE_PRIMARY" ]; then
    STAGING_TABLE="$TABLE_SECONDARY"
  else
    STAGING_TABLE="$TABLE_PRIMARY"
  fi
else
  ACTIVE_TABLE_WAS_SET="0"
  STAGING_TABLE="$TABLE_PRIMARY"
fi

log_info "Active table: ${ACTIVE_TABLE}. Staging table: ${STAGING_TABLE}."
table_flush "$STAGING_TABLE"

"$BUILDER" || {
  table_flush "$STAGING_TABLE"
  log_error "builder.sh failed."
  exit 1
}

ROUTE_TABLE="$STAGING_TABLE" "$APPLY_ROUTES" || {
  table_flush "$STAGING_TABLE"
  log_error "apply-routes.sh failed."
  exit 1
}

rules_delete "$ACTIVE_TABLE"

if ! rules_add "$STAGING_TABLE"; then
  table_flush "$STAGING_TABLE"
  log_error "Failed to enable policy rules for table ${STAGING_TABLE}. Attempting rollback."
  if rules_add "$ACTIVE_TABLE"; then
    log_info "Rollback succeeded. Policy rules restored for table ${ACTIVE_TABLE}."
  else
    log_error "Rollback failed. Policy rules for table ${ACTIVE_TABLE} could not be restored."
  fi
  exit 1
fi

if ! active_table_write "$STAGING_TABLE"; then
  table_flush "$STAGING_TABLE"
  log_error "Failed to update active-table. Attempting rollback."
  rules_delete "$STAGING_TABLE"
  if rules_add "$ACTIVE_TABLE"; then
    log_info "Rollback succeeded. Policy rules restored for table ${ACTIVE_TABLE}."
  else
    log_error "Rollback failed. Policy rules for table ${ACTIVE_TABLE} could not be restored."
  fi
  exit 1
fi

if [ "$ACTIVE_TABLE" != "$STAGING_TABLE" ]; then
  table_flush "$ACTIVE_TABLE"
fi

if [ "$ACTIVE_TABLE_WAS_SET" = "1" ]; then
  log_info "Policy rules switched from $(rule_desc "$ACTIVE_TABLE") to $(rule_desc "$STAGING_TABLE")."
else
  log_info "Policy rules enabled for $(rule_desc "$STAGING_TABLE")."
fi
log_info "Daily refresh completed."
msg "Refresh completed."

exit 0
