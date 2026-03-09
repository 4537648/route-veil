#!/bin/sh

CONFIG="/opt/etc/route-veil/config"
[ -f "$CONFIG" ] || exit 0
. "$CONFIG"

log_info() {
  logger -t "route-veil/hook" "$1"
}

# https://github.com/ndmsystems/packages/wiki/Opkg-Component
[ "$1" != "hook" ] && exit 0
[ "$system_name" != "$IFACE" ] && exit 0

kill_parser() {
  PIDFILE="${PIDFILE:-/tmp/parser.sh.pid}"
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
    ip rule add iif br0 table 1000 priority 1995 2>/dev/null
    log_info "Tunnel interface \"${IFACE}\" is up. Policy rule enabled for br0 -> table 1000."
    /opt/etc/route-veil/parser.sh &
    log_info "parser.sh started."
  ;;
  no-down-*)
    kill_parser
    ip rule del iif br0 table 1000 priority 1995 2>/dev/null
    log_info "Tunnel interface \"${IFACE}\" is down. Policy rule disabled for br0 -> table 1000."
  ;;
esac

exit 0
