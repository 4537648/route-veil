#!/bin/sh

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1" >&2
}

log_info() {
  logger -t "route-veil/uninstall" "$1"
}

log_error() {
  logger -t "route-veil/uninstall" "Error: $1"
}

failure() {
  error_msg "$1"
  log_error "$1"
  exit 1
}

delete_file() {
  if [ -f "$1" ]; then
    if rm "$1" 2>/dev/null; then
      msg "${2:-"File"} \"${1##*/}\" removed."
    else
      error_msg "Failed to remove ${3:-"file"} \"${1##*/}\"."
    fi
  else
    msg "${2:-"File"} \"${1##*/}\" does not exist."
  fi
}

INSTALL_DIR="/opt/etc/route-veil"
CONFIG="${INSTALL_DIR}/config"
RULE_PRIORITY="1995"

TABLE_PRIMARY="1000"
TABLE_SECONDARY="1001"

[ -f "$CONFIG" ] && . "$CONFIG"

RULE_IIF_LIST="${RULE_IIF_LIST-br0}"
TABLE_PRIMARY="${TABLE_PRIMARY:-1000}"
TABLE_SECONDARY="${TABLE_SECONDARY:-1001}"

rules_delete() {
  if [ -n "$RULE_IIF_LIST" ]; then
    for iface in $RULE_IIF_LIST; do
      ip rule del iif "$iface" table "$1" priority "$RULE_PRIORITY" 2>/dev/null || true
    done
  else
    ip rule del table "$1" priority "$RULE_PRIORITY" 2>/dev/null || true
  fi
}

for _tool in ip rm; do
  command -v "$_tool" >/dev/null 2>&1 || \
  failure "\"${_tool}\" is required to run this script."
done

# https://stackoverflow.com/a/226724
printf "%s" "Proceed with removal? [y/n] "
read yn
case "$yn" in
  [Yy]*) ;;
      *) msg "Removal cancelled."; exit 1;;
esac

log_info "Removal started."

for _table in "$TABLE_PRIMARY" "$TABLE_SECONDARY"; do
  if ip route flush table "$_table"; then
    msg "Routing table #${_table} flushed."
    log_info "Routing table #${_table} flushed."
  fi
done

for _table in "$TABLE_PRIMARY" "$TABLE_SECONDARY"; do
  rules_delete "$_table"
  msg "Routing rules for table #${_table} removed."
  log_info "Routing rules for table #${_table} removed."
done

delete_file "/opt/etc/cron.daily/routing_table_update" "Symlink" "symlink"
delete_file "/opt/etc/ndm/ifstatechanged.d/ip_rule_switch" "Symlink" "symlink"
log_info "Scheduled job and tunnel state hook removed."

for _file in \
  config apply-routes.sh start-stop.sh uninstall.sh builder.sh refresh.sh upgrade.sh route-list.txt active-table; do
  delete_file "${INSTALL_DIR}/${_file}"
done

for _file in ip.txt domain.txt domain-asn.txt asn.txt; do
  delete_file "${INSTALL_DIR}/sources/${_file}"
done

if [ -d "${INSTALL_DIR}/sources" ] && \
  [ "$(echo "${INSTALL_DIR}/sources/"*)" = "${INSTALL_DIR}/sources/*" ]; then
  if rm -r "${INSTALL_DIR}/sources" 2>/dev/null; then
    msg "Directory \"${INSTALL_DIR}/sources\" removed."
  else
    error_msg "Failed to remove directory \"${INSTALL_DIR}/sources\"."
  fi
fi

# https://unix.stackexchange.com/a/615900
if [ -d "${INSTALL_DIR}" ] && \
  [ "$(echo "${INSTALL_DIR}/"*)" = "${INSTALL_DIR}/*" ]; then
  if rm -r "${INSTALL_DIR}" 2>/dev/null; then
    msg "Directory \"${INSTALL_DIR}\" removed."
  else
    error_msg "Failed to remove directory \"${INSTALL_DIR}\"."
  fi
fi

/opt/etc/init.d/S10cron restart >/dev/null 2>&1 && \
msg "Cron restarted."

printf "%s\n" "---" "Removal completed."
log_info "Removal completed."

exit 0
