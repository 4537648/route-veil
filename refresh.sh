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
PARSER="${INSTALL_DIR}/parser.sh"
CONFIG="${INSTALL_DIR}/config"
RULE_PRIORITY="1995"

rule_desc() {
  if [ -n "$RULE_IIF" ]; then
    printf "%s\n" "${RULE_IIF} -> table $1"
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

rule_delete() {
  if [ -n "$RULE_IIF" ]; then
    ip rule del iif "$RULE_IIF" table "$1" priority "$RULE_PRIORITY" 2>/dev/null
  else
    ip rule del table "$1" priority "$RULE_PRIORITY" 2>/dev/null
  fi
}

rule_add() {
  if [ -n "$RULE_IIF" ]; then
    ip rule add iif "$RULE_IIF" table "$1" priority "$RULE_PRIORITY" 2>/dev/null
  else
    ip rule add table "$1" priority "$RULE_PRIORITY" 2>/dev/null
  fi
}

table_flush() {
  ip route flush table "$1" >/dev/null 2>&1
}

for _file in "$BUILDER" "$PARSER"; do
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

RULE_IIF="${RULE_IIF-br0}"
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
  if [ "$ACTIVE_TABLE" = "$TABLE_PRIMARY" ]; then
    STAGING_TABLE="$TABLE_SECONDARY"
  else
    STAGING_TABLE="$TABLE_PRIMARY"
  fi
else
  STAGING_TABLE="$TABLE_PRIMARY"
fi

log_info "Active table: ${ACTIVE_TABLE}. Staging table: ${STAGING_TABLE}."
table_flush "$STAGING_TABLE"

"$BUILDER" || {
  table_flush "$STAGING_TABLE"
  log_error "builder.sh failed."
  exit 1
}

ROUTE_TABLE="$STAGING_TABLE" "$PARSER" || {
  table_flush "$STAGING_TABLE"
  log_error "parser.sh failed."
  exit 1
}

rule_delete "$ACTIVE_TABLE" >/dev/null 2>&1 || true

if ! rule_add "$STAGING_TABLE"; then
  table_flush "$STAGING_TABLE"
  log_error "Failed to enable policy rule for table ${STAGING_TABLE}. Attempting rollback."
  if rule_add "$ACTIVE_TABLE"; then
    log_info "Rollback succeeded. Policy rule restored for table ${ACTIVE_TABLE}."
  else
    log_error "Rollback failed. Policy rule for table ${ACTIVE_TABLE} could not be restored."
  fi
  exit 1
fi

if ! active_table_write "$STAGING_TABLE"; then
  table_flush "$STAGING_TABLE"
  log_error "Failed to update active-table. Attempting rollback."
  rule_delete "$STAGING_TABLE" >/dev/null 2>&1 || true
  if rule_add "$ACTIVE_TABLE"; then
    log_info "Rollback succeeded. Policy rule restored for table ${ACTIVE_TABLE}."
  else
    log_error "Rollback failed. Policy rule for table ${ACTIVE_TABLE} could not be restored."
  fi
  exit 1
fi

table_flush "$ACTIVE_TABLE"
log_info "Policy rule switched from $(rule_desc "$ACTIVE_TABLE") to $(rule_desc "$STAGING_TABLE")."
log_info "Daily refresh completed."
msg "Refresh completed."

exit 0
