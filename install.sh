#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="leadjoy-xpad-device-fix"
VERSION="0.2.0"
HELPER_PATH="/usr/local/libexec/${PROJECT_NAME}"
UNIT_NAME="${PROJECT_NAME}.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
RULE_PATH="/etc/udev/rules.d/99-${PROJECT_NAME}.rules"

usage() {
  cat <<USAGE
${PROJECT_NAME} ${VERSION}

Usage:
  curl -fsSL <raw GitHub URL>/install.sh | bash
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- install --dry-run
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- uninstall
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- status
  curl -fsSL <raw GitHub URL>/install.sh | bash -s -- run

Install options:
  --dry-run             Detect a device and show all planned changes only
  --device VID:PID      Use an explicitly selected USB ID, without scanning
  --vid HEX --pid HEX   Equivalent explicit USB ID options
  --non-interactive     Never prompt; requires --device when no known device is connected

Commands:
  install               Detect/select a device, install and enable the fix (default)
  uninstall             Stop/disable the service and remove installed files
  status                Show service, USB and joystick status
  run                   Register the ID already saved by an installation once

The installer never assumes an example USB ID. It first matches connected IDs
against its known-device list. If no match exists, it asks you to choose a
connected ID or enter one manually. The script uses sudo when necessary.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "[${PROJECT_NAME}] $*"; }

COMMAND="install"
DRY_RUN=false
NONINTERACTIVE=false
DEVICE_ARG=""
VID_ARG=""
PID_ARG=""
while (($#)); do
  case "$1" in
    install|uninstall|status|run)
      COMMAND="$1"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --non-interactive)
      NONINTERACTIVE=true
      shift
      ;;
    --device)
      (($# >= 2)) || die "--device requires VID:PID"
      DEVICE_ARG="$2"
      shift 2
      ;;
    --vid)
      (($# >= 2)) || die "--vid requires a value"
      VID_ARG="$2"
      shift 2
      ;;
    --pid)
      (($# >= 2)) || die "--pid requires a value"
      PID_ARG="$2"
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

normalize_id() {
  local value="$1"
  [[ "$value" =~ ^([[:xdigit:]]{4}):([[:xdigit:]]{4})$ ]] || return 1
  printf '%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]'
}

if [[ -n "$DEVICE_ARG" ]]; then
  [[ -z "$VID_ARG" && -z "$PID_ARG" ]] || die "use either --device or --vid/--pid, not both"
  SELECTED_ID="$(normalize_id "$DEVICE_ARG")" || die "USB ID must look like 4131:3519: $DEVICE_ARG"
elif [[ -n "$VID_ARG" || -n "$PID_ARG" ]]; then
  [[ -n "$VID_ARG" && -n "$PID_ARG" ]] || die "--vid and --pid must be used together"
  SELECTED_ID="$(normalize_id "${VID_ARG}:${PID_ARG}")" || die "VID and PID must each be exactly four hexadecimal digits"
else
  SELECTED_ID=""
fi

# The list is deliberately conservative. Entries are candidates for xpad's
# runtime new_id mechanism, not a promise that every firmware/mode works.
known_device_rows() {
  cat <<'DEVICES'
4131:3519|LeadJoy 天剑 Plus 2.4G receiver|community-observed|User supplied LiteEMF observation; verify on the target machine
37d7:2401|Flydigi Vader 5 Pro 2.4G receiver|documented-project|Dedicated xpad project reports this ID
3537:100f|GameSir Nova 2 Lite receiver|community-recipe|Community xpad new_id recipe; verify firmware/mode
3537:1098|GameSir Nova 2 Lite receiver|community-recipe|Community xpad new_id recipe; verify firmware/mode
2dc8:310a|8BitDo Ultimate 2C 2.4G receiver|community-recipe|Community udev/xpad recipe; verify firmware/mode
2dc8:3106|8BitDo Ultimate 2.4G receiver|community-recipe|Community udev/xpad recipe; verify firmware/mode
DEVICES
}

lookup_known() {
  local wanted="$1" id name confidence note
  while IFS='|' read -r id name confidence note; do
    [[ "$id" == "$wanted" ]] || continue
    DEVICE_NAME="$name"
    DEVICE_CONFIDENCE="$confidence"
    DEVICE_NOTE="$note"
    return 0
  done < <(known_device_rows)
  return 1
}

scan_usb_lines() {
  if command -v lsusb >/dev/null 2>&1; then
    lsusb
    return 0
  fi
  if [[ -d /sys/bus/usb/devices ]]; then
    local path vid pid manufacturer product
    for path in /sys/bus/usb/devices/*; do
      [[ -r "$path/idVendor" && -r "$path/idProduct" ]] || continue
      vid="$(cat "$path/idVendor")"
      pid="$(cat "$path/idProduct")"
      manufacturer="$(cat "$path/manufacturer" 2>/dev/null || true)"
      product="$(cat "$path/product" 2>/dev/null || true)"
      printf 'sysfs %s:%s %s %s\n' "$vid" "$pid" "$manufacturer" "$product"
    done
    return 0
  fi
  return 1
}

scan_usb_ids() {
  scan_usb_lines 2>/dev/null \
    | sed -nE 's/.*([Ii][Dd] |sysfs )([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4}).*/\2:\3/p' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u
}

print_known_list() {
  local id name confidence note
  echo "Known xpad/new_id candidates:"
  printf '%-13s  %-34s  %s\n' "USB ID" "Device" "Evidence"
  while IFS='|' read -r id name confidence note; do
    printf '%-13s  %-34s  %s\n' "$id" "$name" "$confidence"
  done < <(known_device_rows)
}

prompt_read() {
  local prompt="$1"
  [[ "$NONINTERACTIVE" == false && -r /dev/tty && -w /dev/tty ]] || return 1
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r REPLY </dev/tty || return 1
  return 0
}

choose_id_from_file() {
  local file="$1" prompt="$2" count choice selected
  count="$(wc -l < "$file" | tr -d ' ')"
  (( count > 0 )) || return 1
  if (( count == 1 )); then
    selected="$(head -n 1 "$file")"
    printf '%s\n' "$selected"
    return 0
  fi
  echo "$prompt"
  nl -w2 -s') ' "$file"
  prompt_read "选择编号（输入 q 取消）： " || return 1
  [[ "$REPLY" != q ]] || return 1
  [[ "$REPLY" =~ ^[0-9]+$ ]] || return 1
  selected="$(sed -n "${REPLY}p" "$file")"
  [[ -n "$selected" ]] || return 1
  printf '%s\n' "$selected"
}

select_custom_id() {
  prompt_read "输入自定义 VID:PID（例如 1234:abcd）： " || return 1
  SELECTED_ID="$(normalize_id "$REPLY")" || { echo "USB ID 格式错误。" >&2; return 1; }
  DEVICE_NAME="用户自定义设备"
  DEVICE_CONFIDENCE="user-selected"
  DEVICE_NOTE="Not present in the built-in list"
  return 0
}

discover_by_replug_auto() {
  local tmp_dir
  tmp_dir="$(mktemp -d -t "${PROJECT_NAME}.replug.XXXXXX")"
  local result
  if discover_by_replug "$tmp_dir/before" "$tmp_dir/disconnected" "$tmp_dir/after" "$tmp_dir/added"; then
    result=0
  else
    result=$?
  fi
  rm -rf "$tmp_dir"
  return "$result"
}

select_from_connected() {
  local ids_file="$1" known_file="$2" unknown_file="$3"
  local id name confidence note selected
  : > "$known_file"
  : > "$unknown_file"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if lookup_known "$id"; then
      printf '%s|%s|%s\n' "$id" "$DEVICE_NAME" "$DEVICE_CONFIDENCE" >> "$known_file"
    else
      printf '%s\n' "$id" >> "$unknown_file"
    fi
  done < "$ids_file"

  if [[ -s "$known_file" ]]; then
    if [[ "$(wc -l < "$known_file" | tr -d ' ')" == 1 ]]; then
      SELECTED_ID="$(cut -d'|' -f1 "$known_file")"
      lookup_known "$SELECTED_ID"
      log "detected known device: ${DEVICE_NAME} (${SELECTED_ID})"
      return 0
    fi
    echo "Multiple known xpad candidates are connected:"
    nl -w2 -s') ' "$known_file" | cut -d'|' -f1-2
    prompt_read "选择要处理的设备编号（输入 q 取消）： " || return 1
    [[ "$REPLY" =~ ^[0-9]+$ ]] || return 1
    SELECTED_ID="$(sed -n "${REPLY}p" "$known_file" | cut -d'|' -f1)"
    [[ -n "$SELECTED_ID" ]] || return 1
    lookup_known "$SELECTED_ID"
    return 0
  fi

  if [[ -s "$unknown_file" ]]; then
    echo "检测到 USB 设备，但没有设备清单匹配项："
    nl -w2 -s') ' "$unknown_file"
    if prompt_read "输入要尝试的编号，c 自定义 VID:PID，r 断开/重连识别： "; then
      if [[ "$REPLY" == c ]]; then
        select_custom_id
        return $?
      fi
      if [[ "$REPLY" == r ]]; then
        discover_by_replug_auto
        return $?
      fi
      [[ "$REPLY" =~ ^[0-9]+$ ]] || return 1
      SELECTED_ID="$(sed -n "${REPLY}p" "$unknown_file")"
      [[ -n "$SELECTED_ID" ]] || return 1
      DEVICE_NAME="未列入清单的 USB 设备"
      DEVICE_CONFIDENCE="user-selected"
      DEVICE_NOTE="User selected this ID; test the resulting input device"
      return 0
    fi
    return 1
  fi
  return 1
}

discover_by_replug() {
  local before="$1" disconnected="$2" after="$3" added="$4"
  echo "没有检测到设备清单中的手柄。接下来用断开/重连来确定真实 USB ID。"
  echo "请先拔出天剑 Plus 的 USB 接收器或数据线。"
  prompt_read "拔出后按回车继续（输入 q 取消）： " || return 1
  [[ "$REPLY" != q ]] || return 1
  scan_usb_ids > "$disconnected"
  echo "请现在插入接收器或用 USB 连接手柄。"
  prompt_read "插入后按回车继续（输入 q 取消）： " || return 1
  [[ "$REPLY" != q ]] || return 1
  scan_usb_ids > "$after"
  comm -13 <(sort -u "$disconnected") <(sort -u "$after") > "$added"
  if [[ ! -s "$added" ]]; then
    echo "重连前后没有发现新增 USB ID。请确认接收器已插好，或使用 --device VID:PID。" >&2
    return 1
  fi
  if [[ "$(wc -l < "$added" | tr -d ' ')" == 1 ]]; then
    SELECTED_ID="$(cat "$added")"
  else
    SELECTED_ID="$(choose_id_from_file "$added" "重连后新增了多个 USB 设备，请选择手柄/接收器：")" || return 1
  fi
  if lookup_known "$SELECTED_ID"; then
    log "replug discovery matched ${DEVICE_NAME} (${SELECTED_ID})"
  else
    DEVICE_NAME="重连发现的未列入设备"
    DEVICE_CONFIDENCE="replug-discovered"
    DEVICE_NOTE="User should verify whether xpad created a working input device"
  fi
  return 0
}

select_device() {
  local tmp_dir="$1" ids before disconnected after added known unknown
  if [[ -n "$SELECTED_ID" ]]; then
    if lookup_known "$SELECTED_ID"; then :; else
      DEVICE_NAME="用户指定设备"
      DEVICE_CONFIDENCE="explicit"
      DEVICE_NOTE="Explicitly supplied by the user"
    fi
    return 0
  fi
  tmp_dir="$(mktemp -d -t "${PROJECT_NAME}.detect.XXXXXX")"
  ids="$tmp_dir/ids"
  before="$tmp_dir/before"
  disconnected="$tmp_dir/disconnected"
  after="$tmp_dir/after"
  added="$tmp_dir/added"
  known="$tmp_dir/known"
  unknown="$tmp_dir/unknown"
  trap 'rm -rf "$tmp_dir"' RETURN

  if ! scan_usb_ids > "$ids"; then
    echo "无法查询 USB 设备：系统缺少 lsusb，且 /sys/bus/usb/devices 不可用。" >&2
    echo "请安装 usbutils，或使用 --device VID:PID。" >&2
    return 1
  fi
  if [[ -s "$ids" ]] && select_from_connected "$ids" "$known" "$unknown"; then
    return 0
  fi
  if [[ "$NONINTERACTIVE" == true ]]; then
    echo "未找到已知设备，非交互模式不能猜测 USB ID。请使用 --device VID:PID。" >&2
    print_known_list >&2
    return 1
  fi
  printf '%s\n' "" "当前没有自动识别到可用的已知设备。"
  print_known_list
  prompt_read "输入 s 扫描已连接设备，c 自定义 VID:PID，r 进行断开/重连识别，l 选择清单项，q 取消： " || return 1
  case "$REPLY" in
    s)
      scan_usb_ids > "$ids"
      select_from_connected "$ids" "$known" "$unknown"
      ;;
    c)
      select_custom_id
      ;;
    r)
      discover_by_replug "$before" "$disconnected" "$after" "$added"
      ;;
    l)
      known_device_rows | cut -d'|' -f1-3 > "$known"
      echo "请选择清单中的设备。清单项只代表可尝试，不代表兼容性保证。"
      nl -w2 -s') ' "$known" | cut -d'|' -f1-3
      prompt_read "选择编号： " || return 1
      [[ "$REPLY" =~ ^[0-9]+$ ]] || return 1
      SELECTED_ID="$(sed -n "${REPLY}p" "$known" | cut -d'|' -f1)"
      [[ -n "$SELECTED_ID" ]] || return 1
      lookup_known "$SELECTED_ID"
      ;;
    *)
      return 1
      ;;
  esac
}

if [[ "$COMMAND" == install ]]; then
  DETECT_TMP="$(mktemp -d -t "${PROJECT_NAME}.XXXXXX")"
  trap 'rm -rf "$DETECT_TMP"' EXIT
  select_device "$DETECT_TMP" || die "没有选定设备；未进行任何系统修改。"
  [[ -n "${SELECTED_ID:-}" ]] || die "没有选定设备；未进行任何系统修改。"
  VID="${SELECTED_ID%%:*}"
  PID="${SELECTED_ID##*:}"
  log "selected ${DEVICE_NAME} (${VID}:${PID}); evidence=${DEVICE_CONFIDENCE}"
fi

if [[ "$DRY_RUN" == true ]]; then
  SUDO=()
elif ((EUID == 0)); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when this command changes system files"
  SUDO=(sudo)
fi
as_root() { "${SUDO[@]}" "$@"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

make_payloads() {
  TMP_DIR="$(mktemp -d -t "${PROJECT_NAME}.payload.XXXXXX")"
  cat > "${TMP_DIR}/helper" <<HELPER
#!/usr/bin/env bash
set -Eeuo pipefail
VID="${VID}"
PID="${PID}"
NEW_ID="/sys/bus/usb/drivers/xpad/new_id"
log() { logger -t leadjoy-xpad-device-fix -- "\$*" 2>/dev/null || true; }
die() { log "error: \$*"; echo "leadjoy-xpad-device-fix: \$*" >&2; exit 1; }
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
Description=Register ${DEVICE_NAME} (${VID}:${PID}) with Linux xpad
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=${HELPER_PATH} register
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  cat > "${TMP_DIR}/rule" <<RULE
# ${DEVICE_NAME} (${VID}:${PID}) -> Linux xpad
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", RUN+="${HELPER_PATH} register"
RULE
}

show_dry_run() {
  make_payloads
  echo
  echo "DRY RUN: no files or system settings will be changed."
  echo "Selected device: ${DEVICE_NAME} (${VID}:${PID})"
  echo "Evidence: ${DEVICE_CONFIDENCE} — ${DEVICE_NOTE}"
  echo
  echo "Would install:"
  echo "  ${HELPER_PATH}"
  echo "  ${UNIT_PATH}"
  echo "  ${RULE_PATH}"
  echo
  echo "Would run:"
  echo "  systemctl daemon-reload"
  echo "  systemctl enable --now ${UNIT_NAME}"
  echo "  udevadm control --reload-rules"
  echo "  udevadm trigger --subsystem-match=usb --attr-match=idVendor=${VID} --attr-match=idProduct=${PID}"
  echo
  echo "--- service ---"
  cat "${TMP_DIR}/unit"
  echo "--- udev rule ---"
  cat "${TMP_DIR}/rule"
  echo "--- helper ---"
  cat "${TMP_DIR}/helper"
  rm -rf "$TMP_DIR"
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
  as_root udevadm trigger --subsystem-match=usb --attr-match="idVendor=${VID}" --attr-match="idProduct=${PID}"
  log "installed ${DEVICE_NAME} (${VID}:${PID})"
  log "if no input device appears, run the status command and judge whether this ID works"
  rm -rf "$TMP_DIR"
}

uninstall_files() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: would stop/disable ${UNIT_NAME} and remove:"
    echo "  ${HELPER_PATH}"
    echo "  ${UNIT_PATH}"
    echo "  ${RULE_PATH}"
    return 0
  fi
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
  echo
  echo "Connected USB IDs:"
  scan_usb_ids || echo "USB scan unavailable"
  if compgen -G '/dev/input/js*' >/dev/null; then
    echo
    echo "Joystick nodes:"
    ls -l /dev/input/js* || true
  fi
}

case "$COMMAND" in
  install)
    if [[ "$DRY_RUN" == true ]]; then show_dry_run; else install_files; fi
    ;;
  uninstall) uninstall_files ;;
  status) status ;;
  run)
    [[ -x "${HELPER_PATH}" ]] || die "not installed; run install first"
    as_root "${HELPER_PATH}" register
    ;;
esac
