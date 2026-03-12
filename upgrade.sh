#!/bin/sh

check_command() {
  command -v "$1" >/dev/null 2>&1
}

msg() {
  printf "%s\n" "$1"
}

error_msg() {
  printf "[!] %s\n" "$1" >&2
}

log_info() {
  logger -t "route-veil/upgrade" "$1"
}

log_error() {
  logger -t "route-veil/upgrade" "Error: $1"
}

failure() {
  error_msg "$1"
  log_error "$1"
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
    msg "File \"${2##*/}\" updated."
  else
    failure "Failed to download file \"${2##*/}\"."
  fi
}

make_executable() {
  check_command chmod || failure "chmod is required to change file permissions."
  if chmod +x "$1" 2>/dev/null; then
    msg "Executable permission set for file \"${1}\"."
  else
    failure "Failed to set executable permission for file \"${1}\"."
  fi
}

create_symlink() {
  check_command ln || failure "ln is required to create symlinks."
  if ln -sf "$1" "$2" 2>/dev/null; then
    msg "Symlink \"${2##*/}\" created in \"${2%/*}\"."
  else
    failure "Failed to create symlink \"${2##*/}\"."
  fi
}

msg "Upgrading route-veil..."
log_info "Upgrade started."

INSTALL_DIR="/opt/etc/route-veil"
SOURCES_DIR="${INSTALL_DIR}/sources"
REPO_URL="https://raw.githubusercontent.com/4537648/route-veil/main"

check_command mktemp || failure "mktemp is required to prepare self-update."
SELF_UPDATE_FILE="$(mktemp "${TMPDIR:-/tmp}/upgrade.XXXXXX")" || \
failure "Failed to create a temporary file for self-update."

cleanup() {
  rm -f "$SELF_UPDATE_FILE"
}

trap cleanup EXIT INT TERM QUIT HUP

[ -d "$INSTALL_DIR" ] || failure "Directory \"${INSTALL_DIR}\" does not exist. Install route-veil first."

check_command opkg || failure "opkg is required to install packages."
opkg update >/dev/null 2>&1 || failure "Failed to update the Entware package list."

for pkg in bind-dig cron grep ip-full jq python3; do
  [ -n "$(opkg status ${pkg})" ] && continue

  pkg_install "$pkg"
  sleep 1

  if [ "$pkg" = "cron" ]; then
    sed -i 's/^ARGS="-s"$/ARGS=""/' /opt/etc/init.d/S10cron && \
    msg "Disabled cron log spam in the router log."
    /opt/etc/init.d/S10cron restart >/dev/null
  fi
done

for _file in apply-routes.sh start-stop.sh uninstall.sh builder.sh refresh.sh; do
  download "${REPO_URL}/${_file}" "${INSTALL_DIR}/${_file}"
  make_executable "${INSTALL_DIR}/${_file}"
done

download "${REPO_URL}/upgrade.sh" "$SELF_UPDATE_FILE"

if [ ! -d "$SOURCES_DIR" ]; then
  if mkdir -p "$SOURCES_DIR"; then
    msg "Directory \"${SOURCES_DIR}\" created."
  else
    failure "Failed to create directory \"${SOURCES_DIR}\"."
  fi
fi

for _file in ip.txt domain.txt domain-asn.txt asn.txt; do
  if [ ! -f "${SOURCES_DIR}/${_file}" ]; then
    if touch "${SOURCES_DIR}/${_file}" 2>/dev/null; then
      msg "File \"${SOURCES_DIR}/${_file}\" created."
    else
      error_msg "Failed to create file \"${SOURCES_DIR}/${_file}\"."
    fi
  fi
done

create_symlink "${INSTALL_DIR}/start-stop.sh" "/opt/etc/ndm/ifstatechanged.d/ip_rule_switch"
create_symlink "${INSTALL_DIR}/refresh.sh" "/opt/etc/cron.daily/routing_table_update"

check_command mv || failure "mv is required to complete self-update."
mv "$SELF_UPDATE_FILE" "${INSTALL_DIR}/upgrade.sh" || \
failure "Failed to replace file \"upgrade.sh\"."
make_executable "${INSTALL_DIR}/upgrade.sh"

/opt/etc/init.d/S10cron restart >/dev/null 2>&1 && \
msg "Cron restarted."

msg "Local config, sources/, route-list.txt and active-table were preserved."
msg "Review README if the new version introduces manual config changes."
printf "%s\n" "---" "Upgrade completed."
log_info "Upgrade completed."

exit 0
