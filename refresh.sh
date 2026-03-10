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

for _file in "$BUILDER" "$PARSER"; do
  [ -x "$_file" ] || {
    error_msg "\"${_file}\" is required to refresh routes."
    log_error "\"${_file}\" is required to refresh routes."
    exit 1
  }
done

log_info "Daily refresh started."
msg "Refreshing route list and routing table..."

"$BUILDER" || {
  log_error "builder.sh failed."
  exit 1
}

"$PARSER" || {
  log_error "parser.sh failed."
  exit 1
}

log_info "Daily refresh completed."
msg "Refresh completed."

exit 0
