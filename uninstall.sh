#!/bin/sh

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1"
}

log_info() {
  logger -t "route-veil/uninstall" "$1"
}

log_error() {
  logger -t "route-veil/uninstall" "Error: $1"
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

PRJ_DIR="/opt/etc/route-veil"
CONFIG="${PRJ_DIR}/config"

TABLE_PRIMARY="1000"
TABLE_SECONDARY="1001"

[ -f "$CONFIG" ] && . "$CONFIG"

RULE_IIF="${RULE_IIF-br0}"
TABLE_PRIMARY="${TABLE_PRIMARY:-1000}"
TABLE_SECONDARY="${TABLE_SECONDARY:-1001}"

rule_delete() {
  if [ -n "$RULE_IIF" ]; then
    ip rule del iif "$RULE_IIF" table "$1" priority 1995 2>/dev/null
  else
    ip rule del table "$1" priority 1995 2>/dev/null
  fi
}

for _tool in ip rm; do
  command -v "$_tool" >/dev/null 2>&1 || {
    error_msg "\"${_tool}\" is required to run this script."
    log_error "\"${_tool}\" is required to run this script."
    exit 1
  }
done

# https://stackoverflow.com/a/226724
read -p "Proceed with removal? [y/n] " yn
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
  if rule_delete "$_table"; then
    msg "Routing rule for table #${_table} removed."
    log_info "Routing rule for table #${_table} removed."
  fi
done

delete_file "/opt/etc/cron.daily/routing_table_update" "Symlink" "symlink"
delete_file "/opt/etc/ndm/ifstatechanged.d/ip_rule_switch" "Symlink" "symlink"
log_info "Scheduled job and tunnel state hook removed."

for _file in \
  config parser.sh start-stop.sh uninstall.sh builder.sh refresh.sh route-list.txt active-table; do
  delete_file "${PRJ_DIR}/${_file}"
done

for _file in ip.txt domain.txt domain-asn.txt asn.txt; do
  delete_file "${PRJ_DIR}/sources/${_file}"
done

if [ -d "${PRJ_DIR}/sources" ] && \
  [ "$(echo "${PRJ_DIR}/sources/"*)" = "${PRJ_DIR}/sources/*" ]; then
  if rm -r "${PRJ_DIR}/sources" 2>/dev/null; then
    msg "Directory \"${PRJ_DIR}/sources\" removed."
  else
    error_msg "Failed to remove directory \"${PRJ_DIR}/sources\"."
  fi
fi

# https://unix.stackexchange.com/a/615900
if [ -d "${PRJ_DIR}" ] && \
  [ "$(echo "${PRJ_DIR}/"*)" = "${PRJ_DIR}/*" ]; then
  if rm -r "${PRJ_DIR}" 2>/dev/null; then
    msg "Directory \"${PRJ_DIR}\" removed."
  else
    error_msg "Failed to remove directory \"${PRJ_DIR}\"."
  fi
fi

/opt/etc/init.d/S10cron restart >/dev/null 2>&1 && \
msg "Cron restarted."

printf "%s\n" "---" "Removal completed."
log_info "Removal completed."

exit 0
