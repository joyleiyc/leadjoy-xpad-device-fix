#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="tianjian-plus-xpad-fix"
VERSION="0.1.0"
DEFAULT_VID="4131"
DEFAULT_PID="3519"
HELPER_PATH="/usr/local/libexec/${PROJECT_NAME}"
UNIT_NAME="${PROJECT_NAME}.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
RULE_PATH="/etc/udev/rules.d/99-${PROJECT_NAME}.rules"

usage() {
  cat <<USAGE
${PROJECT_NAME} ${VERSION}

Usage:
  curl -fsSL <raw GitHub URL>/install.sh | bash
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- uninstall
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- status
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- run

Commands:
  install      Install and enable the boot service (default)
  uninstall    Stop/disable the service and remove installed files
  status       Show service and controller status
  run          Register the USB ID once without changing the installation

Options:
  --vid HEX    USB vendor ID (default: ${DEFAULT_VID})
  --pid HEX    USB product ID (default: ${DEFAULT_PID})
  -h, --help   Show this help

The script uses sudo when it is not run as root. It does not remove the xpad
kernel module during uninstall because other controllers may be using it.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "[${PROJECT_NAME}] $*"; }

COMMAND="install"
VID="${DEFAULT_VID}"
PID="${DEFAULT_PID}"
while (($#)); do
  case "$1" in
    install|uninstall|status|run)
      COMMAND="$1"
      shift
      ;;
    --vid)
      (($# >= 2)) || die "--vid requires a value"
      VID="$2"
      shift 2
      ;;
    --pid)
      (($# >= 2)) || die "--pid requires a value"
      PID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

[[ "$VID" =~ ^[[:xdigit:]]{4}$ ]] || die "VID must be exactly four hexadecimal digits: $VID"
[[ "$PID" =~ ^[[:xdigit:]]{4}$ ]] || die "PID must be exactly four hexadecimal digits: $PID"
VID="$(printf '%s' "$VID" | tr '[:upper:]' '[:lower:]')"
PID="$(printf '%s' "$PID" | tr '[:upper:]' '[:lower:]')"

if ((EUID == 0)); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when this script is not run as root"
  SUDO=(sudo)
fi

as_root() { "${SUDO[@]}" "$@"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

make_payloads() {
  TMP_DIR="$(mktemp -d -t "${PROJECT_NAME}.XXXXXX")"
  trap 'rm -rf "$TMP_DIR"' EXIT

  cat > "${TMP_DIR}/helper" <<HELPER
#!/usr/bin/env bash
set -Eeuo pipefail
VID="${VID}"
PID="${PID}"
NEW_ID="/sys/bus/usb/drivers/xpad/new_id"

log() { logger -t tianjian-plus-xpad -- "\$*" 2>/dev/null || true; }
die() { log "error: \$*"; echo "tianjian-plus-xpad: \$*" >&2; exit 1; }

modprobe_bin="\$(command -v modprobe 2>/dev/null || true)"
if [[ -z "\$modprobe_bin" ]]; then
  for candidate in /sbin/modprobe /usr/sbin/modprobe; do
    if [[ -x "\$candidate" ]]; then modprobe_bin="\$candidate"; break; fi
  done
fi
[[ -n "\$modprobe_bin" ]] || die "modprobe was not found"

[[ "\${EUID}" -eq 0 ]] || die "must run as root"
"\$modprobe_bin" xpad || die "could not load the xpad kernel module"
[[ -e "\$NEW_ID" ]] || die "xpad does not expose \$NEW_ID; is the xpad driver available?"

# new_id is commonly write-only, so do not try to read it for idempotency.
# A repeated write can return EEXIST; that means another invocation already
# registered the same ID and is safe to treat as success.
if ! write_error="\$(printf '%s %s\\n' "\$VID" "\$PID" > "\$NEW_ID" 2>&1)"; then
  if [[ "\$write_error" =~ [Ee]xist|already ]]; then
    log "USB ID \$VID:\$PID was already registered with xpad"
  else
    die "could not register USB ID \$VID:\$PID with xpad: \$write_error"
  fi
else
  log "registered USB ID \$VID:\$PID with xpad"
fi
HELPER
  chmod 0755 "${TMP_DIR}/helper"

  cat > "${TMP_DIR}/unit" <<UNIT
[Unit]
Description=Register Tianjian Plus controller (${VID}:${PID}) with Linux xpad
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=${HELPER_PATH} register
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  cat > "${TMP_DIR}/rule" <<RULE
# Tianjian Plus / LiteEMF controller (${VID}:${PID}) -> Linux xpad
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", RUN+="${HELPER_PATH} register"
RULE
}

install_files() {
  require_command install
  require_command mktemp
  require_command systemctl
  require_command udevadm
  make_payloads
  as_root install -D -m 0755 "${TMP_DIR}/helper" "${HELPER_PATH}"
  as_root install -D -m 0644 "${TMP_DIR}/unit" "${UNIT_PATH}"
  as_root install -D -m 0644 "${TMP_DIR}/rule" "${RULE_PATH}"
  as_root systemctl daemon-reload
  as_root systemctl enable --now "${UNIT_NAME}"
  as_root udevadm control --reload-rules
  as_root udevadm trigger --subsystem-match=usb --attr-match=idVendor=${VID} --attr-match=idProduct=${PID}
  log "installed for USB ID ${VID}:${PID}"
  log "reconnect the controller if it was already plugged in"
}

uninstall_files() {
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl disable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
    as_root systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  as_root rm -f "${HELPER_PATH}" "${UNIT_PATH}" "${RULE_PATH}"
  if command -v udevadm >/dev/null 2>&1; then
    as_root udevadm control --reload-rules >/dev/null 2>&1 || true
  fi
  log "uninstalled ${PROJECT_NAME}"
  log "the xpad module was left loaded for other controllers"
}

status() {
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl --no-pager --full status "${UNIT_NAME}" || true
  else
    log "systemctl is not available"
  fi
  if command -v lsusb >/dev/null 2>&1; then
    echo
    echo "Matching USB devices (${VID}:${PID}):"
    lsusb -d "${VID}:${PID}" || true
  fi
  if compgen -G '/dev/input/js*' >/dev/null; then
    echo
    echo "Joystick nodes:"
    ls -l /dev/input/js* || true
  fi
}

case "${COMMAND}" in
  install) install_files ;;
  uninstall) uninstall_files ;;
  status) status ;;
  run)
    [[ -x "${HELPER_PATH}" ]] || die "not installed; run install first"
    as_root "${HELPER_PATH}" register
    ;;
esac
