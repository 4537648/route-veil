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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILDER="${SCRIPT_DIR}/builder.sh"
PARSER="${SCRIPT_DIR}/parser.sh"
CONFIG="${SCRIPT_DIR}/config"
RULE_IIF="br0"
RULE_TABLE="1000"
RULE_PRIORITY="1995"

rule_delete() {
  ip rule del iif "$RULE_IIF" table "$RULE_TABLE" priority "$RULE_PRIORITY" 2>/dev/null
}

rule_add() {
  ip rule add iif "$RULE_IIF" table "$RULE_TABLE" priority "$RULE_PRIORITY" 2>/dev/null
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

rule_delete && log_info "Policy rule temporarily disabled for refresh."

"$BUILDER" || {
  log_error "builder.sh failed."
  exit 1
}

"$PARSER" || {
  log_error "parser.sh failed."
  exit 1
}

rule_add
log_info "Policy rule enabled after successful refresh."
log_info "Daily refresh completed."
msg "Refresh completed."

exit 0
