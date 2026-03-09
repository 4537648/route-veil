#!/bin/sh

check_command() {
  command -v "$1" >/dev/null 2>&1
}

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1"
}

failure() {
  error_msg "$1"
  exit 1
}

pkg_install() {
  msg "Installing package \"${1}\"..."
  if opkg install "$1" >/dev/null 2>&1; then
    msg "Package \"${1}\" installed."
  else
    failure "Failed to install package \"${1}\"."
  fi
}

download() {
  check_command curl || failure "curl is required to download files."
  if curl -sfL --connect-timeout 7 "$1" -o "$2"; then
    msg "File \"${2##*/}\" downloaded."
  else
    failure "Failed to download file \"${2##*/}\"."
  fi
}

mk_file_exec() {
  check_command chmod || failure "chmod is required to change file permissions."
  if chmod +x "$1" 2>/dev/null; then
    msg "Executable permission set for file \"${1}\"."
  else
    failure "Failed to set executable permission for file \"${1}\"."
  fi
}

crt_symlink() {
  check_command ln || failure "ln is required to create symlinks."
  if ln -sf "$1" "$2" 2>/dev/null; then
    msg "Symlink \"${2##*/}\" created in \"${2%/*}\"."
  else
    failure "Failed to create symlink \"${2##*/}\"."
fi
}

msg "Installing route-veil..."

INSTALL_DIR="/opt/etc/route-veil"
REPO_URL="https://raw.githubusercontent.com/4537648/route-veil/main"

check_command opkg || failure "opkg is required to install packages."
opkg update >/dev/null 2>&1 || failure "Failed to update the Entware package list."

for pkg in bind-dig cron grep; do
  [ -n "$(opkg status ${pkg})" ] && continue

  pkg_install "$pkg"
  sleep 1

  if [ "$pkg" = "cron" ]; then
    sed -i 's/^ARGS="-s"$/ARGS=""/' /opt/etc/init.d/S10cron && \
    msg "Disabled cron log spam in the router log."
    /opt/etc/init.d/S10cron restart >/dev/null
  fi
done

if [ ! -d "$INSTALL_DIR" ]; then
  if mkdir -p "$INSTALL_DIR"; then
    msg "Directory \"${INSTALL_DIR}\" created."
  else
    failure "Failed to create directory \"${INSTALL_DIR}\"."
  fi
fi

[ ! -f "${INSTALL_DIR}/config" ] && download "${REPO_URL}/config" "${INSTALL_DIR}/config"

for _file in parser.sh start-stop.sh uninstall.sh; do
  download "${REPO_URL}/${_file}" "${INSTALL_DIR}/${_file}"
  mk_file_exec "${INSTALL_DIR}/${_file}"
done

crt_symlink "${INSTALL_DIR}/parser.sh" "/opt/etc/cron.daily/routing_table_update"
crt_symlink "${INSTALL_DIR}/start-stop.sh" "/opt/etc/ndm/ifstatechanged.d/ip_rule_switch"

if [ ! -f "${INSTALL_DIR}/route-veil-list.txt" ]; then
  if touch "${INSTALL_DIR}/route-veil-list.txt" 2>/dev/null; then
    msg "File \"${INSTALL_DIR}/route-veil-list.txt\" created."
  else
    error_msg "Failed to create file \"${INSTALL_DIR}/route-veil-list.txt\"."
  fi
fi

printf "%s\n" "---" "Installation completed."
msg "Set the VPN interface name in config and populate route-veil-list.txt."

exit 0
