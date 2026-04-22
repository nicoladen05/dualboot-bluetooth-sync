#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_ROOT=""
SELECTED_MOUNT=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEBUG=0
SYNC_DIRECTION="windows-to-linux"
WINDOWS_HIVE_BACKUP_DONE=0
WINDOWS_HIVE_BACKUP_PATH=""
REGED_PREFIX="DUALBOOTBTSYNC"

declare -a CANDIDATE_DEVICES=()
declare -a CANDIDATE_FSTYPES=()
declare -a CANDIDATE_SIZES=()
declare -A LINUX_DEVICE_PATHS=()
declare -A LINUX_DEVICE_NAMES=()
declare -a UPDATED_DEVICES=()
declare -a SKIPPED_DEVICES=()

log() {
  printf '[*] %s\n' "$*" >&2
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

debug() {
  (( DEBUG )) || return 0
  printf '[debug] %s\n' "$*" >&2
}

cleanup() {
  if [[ -n "$SELECTED_MOUNT" ]] && mountpoint -q "$SELECTED_MOUNT" 2>/dev/null; then
    umount "$SELECTED_MOUNT" || warn "Failed to unmount $SELECTED_MOUNT"
  fi

  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT INT TERM

require_root() {
  [[ $(id -u) -eq 0 ]] || die "Run this script as root, e.g. sudo $SCRIPT_NAME"
}

require_commands() {
  local missing=()
  local cmd
  for cmd in bluetoothctl chntpw lsblk mount mountpoint python3 systemctl umount; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ $SYNC_DIRECTION == "linux-to-windows" ]] && ! command -v reged >/dev/null 2>&1; then
    missing+=("reged")
  fi

  [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --to-windows)
        SYNC_DIRECTION="linux-to-windows"
        shift
        ;;
      --to-linux)
        SYNC_DIRECTION="windows-to-linux"
        shift
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      -h|--help)
        cat <<EOF
Usage: $SCRIPT_NAME [--to-linux|--to-windows] [--debug]

Options:
  --to-linux  Copy Bluetooth keys from Windows into local Linux BlueZ data (default)
  --to-windows  Copy Bluetooth keys from local Linux BlueZ data into the Windows registry
  --debug   Print extracted registry values and matching decisions
  -h, --help  Show this help message
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

normalize_mac_nosep() {
  local input=${1^^}
  input=${input//:/}
  input=${input//-/}
  printf '%s\n' "$input"
}

format_mac_colon() {
  local mac
  mac=$(normalize_mac_nosep "$1")

  [[ $mac =~ ^[0-9A-F]{12}$ ]] || return 1

  printf '%s:%s:%s:%s:%s:%s\n' \
    "${mac:0:2}" "${mac:2:2}" "${mac:4:2}" \
    "${mac:6:2}" "${mac:8:2}" "${mac:10:2}"
}

prompt_yes_no() {
  local prompt=$1
  local reply

  while true; do
    read -r -p "$prompt [y/N] " reply
    case ${reply,,} in
      y|yes) return 0 ;;
      n|no|'') return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

mount_partition() {
  local device=$1
  local target=$2
  local mode=$3

  mount -o "$mode" "$device" "$target" 2>/dev/null
}

discover_windows_partitions() {
  local probe_root probe_dir device fstype size kind

  probe_root=$(mktemp -d "$TMP_ROOT/probe.XXXXXX")

  while read -r device fstype size kind; do
    [[ $kind == "part" ]] || continue
    [[ -n $fstype ]] || continue

    probe_dir="$probe_root/$(basename "$device")"
    mkdir -p "$probe_dir"

    if mount_partition "$device" "$probe_dir" ro; then
      if [[ -f "$probe_dir/Windows/System32/config/SYSTEM" ]]; then
        CANDIDATE_DEVICES+=("$device")
        CANDIDATE_FSTYPES+=("$fstype")
        CANDIDATE_SIZES+=("$size")
      fi
      umount "$probe_dir" || warn "Failed to unmount probe mount $probe_dir"
    fi

    rmdir "$probe_dir" 2>/dev/null || true
  done < <(lsblk -nrpo NAME,FSTYPE,SIZE,TYPE)

  rmdir "$probe_root" 2>/dev/null || true

  [[ ${#CANDIDATE_DEVICES[@]} -gt 0 ]] || die "No Windows partitions with Windows/System32/config/SYSTEM were found."
}

select_windows_partition() {
  local choice i count

  count=${#CANDIDATE_DEVICES[@]}
  log "Windows partitions found:"
  for ((i = 0; i < count; i++)); do
    printf '  %d) %s  %s  %s\n' "$((i + 1))" "${CANDIDATE_DEVICES[i]}" "${CANDIDATE_FSTYPES[i]}" "${CANDIDATE_SIZES[i]}" >&2
  done

  while true; do
    read -r -p "Select the Windows partition to use: " choice
    [[ $choice =~ ^[0-9]+$ ]] || { warn "Enter a number from the list."; continue; }
    if (( choice >= 1 && choice <= count )); then
      printf '%s\n' "${CANDIDATE_DEVICES[choice - 1]}"
      return 0
    fi
    warn "Enter a number from the list."
  done
}

mount_selected_partition() {
  local device=$1
  local mode=ro

  if [[ $SYNC_DIRECTION == "linux-to-windows" ]]; then
    mode=rw
  fi

  SELECTED_MOUNT=$(mktemp -d "$TMP_ROOT/windows.XXXXXX")
  mount_partition "$device" "$SELECTED_MOUNT" "$mode" || die "Failed to mount $device $mode. If Windows Fast Startup is enabled, disable it and try again."
  debug "Mounted $device at $SELECTED_MOUNT with mode $mode"
}

chntpw_run() {
  local hive=$1
  local commands=$2
  printf '%s\n' "$commands" | chntpw -e "$hive" 2>/dev/null
}

registry_ls() {
  local hive=$1
  local path=$2
  local commands
  commands=$(printf 'cd %s\nls\nq\n' "$path")
  chntpw_run "$hive" "$commands"
}

registry_hex() {
  local hive=$1
  local path=$2
  local value=$3
  local commands
  commands=$(printf 'cd %s\nhex %s\nq\n' "$path" "$value")
  chntpw_run "$hive" "$commands"
}

parse_subkeys() {
  python3 -c 'import re, sys
for line in sys.stdin:
    match = re.match(r"^\s+<([^>]+)>\s*$", line.rstrip("\n"))
    if match:
        print(match.group(1))'
}

parse_value_names() {
  python3 -c 'import re, sys
for line in sys.stdin:
    match = re.search(r"REG_[A-Z0-9_]+\s+<([^>]+)>", line)
    if match:
        print(match.group(1))'
}

parse_dword_value() {
  local value_name=$1

  python3 -c 'import re, sys
value_name = sys.argv[1]
pattern = re.compile(rf"REG_DWORD\s+<{re.escape(value_name)}>\s+([0-9]+)\s+\[0x[0-9a-fA-F]+\]")
for line in sys.stdin:
    match = pattern.search(line)
    if match:
        print(match.group(1))
        break' "$value_name"
}

extract_hexdump() {
  python3 -c 'import re, sys
chunks = []
for line in sys.stdin:
    if line.startswith(":"):
        chunks.extend(re.findall(r"\b[0-9A-F]{2}\b", line))
print("".join(chunks))'
}

little_endian_hex_to_decimal() {
  local hex=$1

  [[ -n $hex ]] || {
    printf '0\n'
    return 0
  }

  python3 - "$hex" <<'PY'
import sys

value = sys.argv[1]
raw = bytes.fromhex(value)
print(int.from_bytes(raw, byteorder='little', signed=False))
PY
}

hex_to_reg_binary() {
  local hex=${1^^}

  python3 - "$hex" <<'PY'
import sys

value = sys.argv[1].strip()
if len(value) % 2 != 0:
    raise SystemExit('invalid hex length')
print('hex:' + ','.join(value[i:i + 2].lower() for i in range(0, len(value), 2)))
PY
}

decimal_to_reg_dword() {
  local value=$1

  python3 - "$value" <<'PY'
import sys

value = int(sys.argv[1])
if value < 0 or value > 0xFFFFFFFF:
    raise SystemExit('DWORD out of range')
print(f'dword:{value:08x}')
PY
}

decimal_to_reg_qword() {
  local value=$1

  python3 - "$value" <<'PY'
import sys

value = int(sys.argv[1])
if value < 0 or value > 0xFFFFFFFFFFFFFFFF:
    raise SystemExit('QWORD out of range')
raw = value.to_bytes(8, byteorder='little', signed=False)
print('hex(b):' + ','.join(f'{byte:02x}' for byte in raw))
PY
}

extract_linux_device_material() {
  local info_file=$1

  python3 - "$info_file" <<'PY'
import configparser
import shlex
import sys

path = sys.argv[1]
cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform = str

with open(path, 'r', encoding='utf-8') as handle:
    cfg.read_file(handle)

def get(section, key):
    if cfg.has_section(section) and cfg.has_option(section, key):
        return cfg.get(section, key).strip()
    return ''

def first_ltk_value(key):
    for section in ('LongTermKey', 'PeripheralLongTermKey', 'SlaveLongTermKey'):
        value = get(section, key)
        if value:
            return value
    return ''

values = {
    'DEVICE_KIND': 'classic' if get('LinkKey', 'Key') else ('ble' if first_ltk_value('Key') else ''),
    'LINK_KEY': get('LinkKey', 'Key').upper(),
    'LTK': first_ltk_value('Key').upper(),
    'ENC_SIZE': first_ltk_value('EncSize'),
    'EDIV': first_ltk_value('EDiv'),
    'RAND': first_ltk_value('Rand'),
    'IRK': get('IdentityResolvingKey', 'Key').upper(),
    'CSRK': get('LocalSignatureKey', 'Key').upper(),
    'CSRK_INBOUND': get('RemoteSignatureKey', 'Key').upper(),
}

for key, value in values.items():
    print(f'{key}={shlex.quote(value)}')
PY
}

ensure_windows_hive_backup() {
  local hive=$1
  local backup_dir=/var/backups/dualboot-bluetooth-sync

  (( WINDOWS_HIVE_BACKUP_DONE == 0 )) || return 0

  mkdir -p "$backup_dir" || die "Failed to create backup directory $backup_dir"
  WINDOWS_HIVE_BACKUP_PATH="$backup_dir/SYSTEM.$TIMESTAMP"
  cp -a "$hive" "$WINDOWS_HIVE_BACKUP_PATH" || die "Failed to back up Windows SYSTEM hive to $WINDOWS_HIVE_BACKUP_PATH"
  WINDOWS_HIVE_BACKUP_DONE=1
  log "Backed up Windows SYSTEM hive to $WINDOWS_HIVE_BACKUP_PATH"
}

registry_import_values() {
  local hive=$1
  local section_key=$2
  shift 2
  local reg_file="$TMP_ROOT/import.$RANDOM.reg"
  local line status

  {
    printf 'Windows Registry Editor Version 5.00\r\n\r\n'
    printf '[%s\\%s]\r\n' "$REGED_PREFIX" "$section_key"
    for line in "$@"; do
      printf '%s\r\n' "$line"
    done
  } > "$reg_file"

  debug "Importing Windows registry values into $section_key"
  if (( DEBUG )); then
    while IFS= read -r line; do
      debug "$line"
    done < "$reg_file"
  fi

  reged -N -E -I -C "$hive" "$REGED_PREFIX" "$reg_file" >/dev/null 2>&1
  status=$?
  rm -f "$reg_file"

  [[ $status -eq 2 ]] || die "Failed to import Windows registry updates into $section_key. Re-run with --debug for details."
}

get_current_control_set() {
  local hive=$1
  local select_output current

  select_output=$(registry_ls "$hive" '\Select')
  current=$(printf '%s\n' "$select_output" | parse_dword_value Current)

  [[ -n $current ]] || die "Failed to determine the active Windows ControlSet from the SYSTEM hive."
  debug "Active Windows control set: ControlSet$(printf '%03d' "$current")"
  printf 'ControlSet%03d\n' "$current"
}

get_local_controller_mac() {
  local controller
  controller=$(bluetoothctl show | awk '/^Controller / { print $2; exit }')
  [[ -n $controller ]] || die "No active Bluetooth controller reported by bluetoothctl show."
  debug "Active Linux controller: $controller"
  printf '%s\n' "$controller"
}

load_linux_devices() {
  local adapter_dir=$1
  local path mac info_file name

  [[ -d $adapter_dir ]] || die "BlueZ adapter directory $adapter_dir does not exist. Pair devices on Linux first."

  for path in "$adapter_dir"/*; do
    [[ -d $path ]] || continue
    mac=$(basename "$path")
    [[ $mac =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || continue
    LINUX_DEVICE_PATHS["$(normalize_mac_nosep "$mac")"]=$path

    info_file="$path/info"
    name=""
    if [[ -f $info_file ]]; then
      name=$(awk -F= 'BEGIN { section = "" } /^\[/ { section = $0 } section == "[General]" && $1 == "Name" { print substr($0, index($0, "=") + 1); exit }' "$info_file")
    fi
    LINUX_DEVICE_NAMES["$(normalize_mac_nosep "$mac")"]=$name
  done
}

choose_windows_adapter() {
  local hive=$1
  local keys_path=$2
  local local_controller=$3
  local adapters_output adapter exact normalized i choice
  local -a adapters=()

  adapters_output=$(registry_ls "$hive" "$keys_path")
  while read -r adapter; do
    [[ -n $adapter ]] || continue
    adapters+=("$adapter")
  done < <(printf '%s\n' "$adapters_output" | parse_subkeys)

  [[ ${#adapters[@]} -gt 0 ]] || die "No Bluetooth adapters were found in the Windows registry hive."

  normalized=$(normalize_mac_nosep "$local_controller")
  for adapter in "${adapters[@]}"; do
    if [[ ${adapter^^} == "$normalized" ]]; then
      debug "Matched Windows adapter ${adapter^^} to Linux controller $local_controller"
      printf '%s\n' "$adapter"
      return 0
    fi
  done

  warn "The local Bluetooth controller $local_controller was not found in the Windows registry hive."
  log "Windows Bluetooth adapters found:"
  for ((i = 0; i < ${#adapters[@]}; i++)); do
    exact=$(format_mac_colon "${adapters[i]}" 2>/dev/null || printf '%s' "${adapters[i]}")
    printf '  %d) %s\n' "$((i + 1))" "$exact" >&2
  done

  while true; do
    read -r -p "Select the Windows Bluetooth adapter to use: " choice
    [[ $choice =~ ^[0-9]+$ ]] || { warn "Enter a number from the list."; continue; }
    if (( choice >= 1 && choice <= ${#adapters[@]} )); then
      printf '%s\n' "${adapters[choice - 1]}"
      return 0
    fi
    warn "Enter a number from the list."
  done
}

device_label() {
  local mac=$1
  local normalized name
  normalized=$(normalize_mac_nosep "$mac")
  name=${LINUX_DEVICE_NAMES[$normalized]:-}
  if [[ -n $name ]]; then
    printf '%s (%s)' "$name" "$(format_mac_colon "$normalized")"
  else
    printf '%s' "$(format_mac_colon "$normalized")"
  fi
}

resolve_linux_device_path() {
  local windows_mac=$1
  local normalized path prefix mac candidate_count choice
  local -a matches=()
  local -a match_macs=()

  normalized=$(normalize_mac_nosep "$windows_mac")

  if [[ -n ${LINUX_DEVICE_PATHS[$normalized]:-} ]]; then
    debug "Exact Linux device match for $(format_mac_colon "$normalized"): ${LINUX_DEVICE_PATHS[$normalized]}"
    printf '%s\n' "${LINUX_DEVICE_PATHS[$normalized]}"
    return 0
  fi

  prefix=${normalized:0:10}
  for mac in "${!LINUX_DEVICE_PATHS[@]}"; do
    if [[ ${mac:0:10} == "$prefix" ]]; then
      matches+=("${LINUX_DEVICE_PATHS[$mac]}")
      match_macs+=("$mac")
    fi
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    debug "No Linux device match for Windows device $(format_mac_colon "$normalized")"
    SKIPPED_DEVICES+=("$(format_mac_colon "$normalized"): no matching Linux-paired device directory found")
    return 1
  fi

  if [[ ${#matches[@]} -eq 1 ]]; then
    if prompt_yes_no "Use $(device_label "${match_macs[0]}") for Windows device $(format_mac_colon "$normalized")?"; then
      printf '%s\n' "${matches[0]}"
      return 0
    fi
    SKIPPED_DEVICES+=("$(format_mac_colon "$normalized"): declined single close-match candidate")
    return 1
  fi

  log "Multiple possible Linux device directories match Windows device $(format_mac_colon "$normalized"):"
  for ((choice = 0; choice < ${#matches[@]}; choice++)); do
    printf '  %d) %s\n' "$((choice + 1))" "$(device_label "${match_macs[choice]}")" >&2
  done
  printf '  %d) skip\n' "$(( ${#matches[@]} + 1 ))" >&2

  while true; do
    read -r -p "Choose a Linux device directory to reuse: " candidate_count
    [[ $candidate_count =~ ^[0-9]+$ ]] || { warn "Enter a number from the list."; continue; }
    if (( candidate_count == ${#matches[@]} + 1 )); then
      SKIPPED_DEVICES+=("$(format_mac_colon "$normalized"): skipped by user from multiple close-match candidates")
      return 1
    fi
    if (( candidate_count >= 1 && candidate_count <= ${#matches[@]} )); then
      printf '%s\n' "${matches[candidate_count - 1]}"
      return 0
    fi
    warn "Enter a number from the list."
  done
}

prepare_linux_device_path() {
  local windows_mac=$1
  local source_path=$2
  local desired_mac desired_path current_mac current_norm desired_norm current_name

  desired_mac=$(format_mac_colon "$windows_mac")
  desired_norm=$(normalize_mac_nosep "$windows_mac")
  current_mac=$(basename "$source_path")
  current_norm=$(normalize_mac_nosep "$current_mac")

  if [[ $current_norm == "$desired_norm" ]]; then
    printf '%s\n' "$source_path"
    return 0
  fi

  desired_path=$(dirname "$source_path")/$desired_mac
  if [[ -e $desired_path ]]; then
    SKIPPED_DEVICES+=("$desired_mac: target path $desired_path already exists")
    return 1
  fi

  current_name=${LINUX_DEVICE_NAMES[$current_norm]:-unknown device}
  if ! prompt_yes_no "Rename Linux device directory $current_mac ($current_name) to $desired_mac to match Windows?"; then
    SKIPPED_DEVICES+=("$desired_mac: declined directory rename from $current_mac")
    return 1
  fi

  mv "$source_path" "$desired_path"
  unset 'LINUX_DEVICE_PATHS[$current_norm]'
  LINUX_DEVICE_PATHS[$desired_norm]=$desired_path
  LINUX_DEVICE_NAMES[$desired_norm]=${LINUX_DEVICE_NAMES[$current_norm]:-}
  unset 'LINUX_DEVICE_NAMES[$current_norm]'

  printf '%s\n' "$desired_path"
}

backup_info_file() {
  local info_file=$1
  cp -a "$info_file" "$info_file.bak.$TIMESTAMP"
}

update_info_file() {
  local info_file=$1
  local kind=$2
  local link_key=$3
  local ltk=$4
  local enc_size=$5
  local ediv=$6
  local rand=$7
  local irk=$8
  local csrk=$9
  local csrk_inbound=${10}

  INFO_FILE=$info_file \
  DEVICE_KIND=$kind \
  LINK_KEY=$link_key \
  LTK=$ltk \
  ENC_SIZE=$enc_size \
  EDIV=$ediv \
  RAND=$rand \
  IRK=$irk \
  CSRK=$csrk \
  CSRK_INBOUND=$csrk_inbound \
  python3 - <<'PY'
import configparser
import os

path = os.environ['INFO_FILE']
kind = os.environ['DEVICE_KIND']
link_key = os.environ['LINK_KEY']
ltk = os.environ['LTK']
enc_size = os.environ['ENC_SIZE']
ediv = os.environ['EDIV']
rand = os.environ['RAND']
irk = os.environ['IRK']
csrk = os.environ['CSRK']
csrk_inbound = os.environ['CSRK_INBOUND']

cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform = str

with open(path, 'r', encoding='utf-8') as handle:
    cfg.read_file(handle)

def ensure(section):
    if not cfg.has_section(section):
        cfg.add_section(section)

def preserve_or_default(section, key, default):
    if cfg.has_option(section, key):
        return cfg.get(section, key)
    return default

if kind == 'classic':
    ensure('LinkKey')
    cfg.set('LinkKey', 'Key', link_key)
else:
    # Leave device-specific extra LTK sections intact by default.
    ensure('LongTermKey')
    cfg.set('LongTermKey', 'Key', ltk)
    cfg.set('LongTermKey', 'EncSize', enc_size)
    cfg.set('LongTermKey', 'EDiv', ediv)
    cfg.set('LongTermKey', 'Rand', rand)
    cfg.set('LongTermKey', 'Authenticated', preserve_or_default('LongTermKey', 'Authenticated', 'false'))

    if irk:
        ensure('IdentityResolvingKey')
        cfg.set('IdentityResolvingKey', 'Key', irk)

    if csrk:
        ensure('LocalSignatureKey')
        cfg.set('LocalSignatureKey', 'Key', csrk)
        cfg.set('LocalSignatureKey', 'Counter', preserve_or_default('LocalSignatureKey', 'Counter', '0'))
        cfg.set('LocalSignatureKey', 'Authenticated', preserve_or_default('LocalSignatureKey', 'Authenticated', 'false'))

    if csrk_inbound:
        ensure('RemoteSignatureKey')
        cfg.set('RemoteSignatureKey', 'Key', csrk_inbound)
        cfg.set('RemoteSignatureKey', 'Counter', preserve_or_default('RemoteSignatureKey', 'Counter', '0'))
        cfg.set('RemoteSignatureKey', 'Authenticated', preserve_or_default('RemoteSignatureKey', 'Authenticated', 'false'))

with open(path, 'w', encoding='utf-8') as handle:
    cfg.write(handle, space_around_delimiters=False)
PY
}

process_classic_device() {
  local hive=$1
  local adapter_path=$2
  local windows_registry_name=$3
  local source_path final_path info_file key_hex
  local windows_mac

  windows_mac=$(normalize_mac_nosep "$windows_registry_name")

  key_hex=$(registry_hex "$hive" "$adapter_path" "$windows_registry_name" | extract_hexdump)
  debug "Classic device $(format_mac_colon "$windows_mac"): LinkKey=$key_hex"
  [[ -n $key_hex ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): failed to extract classic LinkKey from Windows registry")
    return 0
  }

  if ! source_path=$(resolve_linux_device_path "$windows_mac"); then
    return 0
  fi

  if ! final_path=$(prepare_linux_device_path "$windows_mac" "$source_path"); then
    return 0
  fi

  debug "Classic device $(format_mac_colon "$windows_mac"): using Linux path $final_path"

  info_file="$final_path/info"
  [[ -f $info_file ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): missing Linux info file at $info_file")
    return 0
  }

  backup_info_file "$info_file"
  update_info_file "$info_file" classic "$key_hex" '' '' '' '' '' '' ''
  UPDATED_DEVICES+=("$(device_label "$windows_mac"): updated [LinkKey] from Windows")
}

process_ble_device() {
  local hive=$1
  local device_path=$2
  local windows_registry_name=$3
  local ls_output source_path final_path info_file
  local ltk key_length ediv erand_hex rand irk csrk csrk_inbound
  local windows_mac

  windows_mac=$(normalize_mac_nosep "$windows_registry_name")

  ls_output=$(registry_ls "$hive" "$device_path")
  ltk=$(registry_hex "$hive" "$device_path" LTK | extract_hexdump)
  key_length=$(printf '%s\n' "$ls_output" | parse_dword_value KeyLength)
  ediv=$(printf '%s\n' "$ls_output" | parse_dword_value EDIV)
  erand_hex=$(registry_hex "$hive" "$device_path" ERand | extract_hexdump)
  rand=$(little_endian_hex_to_decimal "$erand_hex")
  irk=''
  csrk=''
  csrk_inbound=''

  if printf '%s\n' "$ls_output" | parse_value_names | grep -qx IRK; then
    irk=$(registry_hex "$hive" "$device_path" IRK | extract_hexdump)
  fi
  if printf '%s\n' "$ls_output" | parse_value_names | grep -qx CSRK; then
    csrk=$(registry_hex "$hive" "$device_path" CSRK | extract_hexdump)
  fi
  if printf '%s\n' "$ls_output" | parse_value_names | grep -qx CSRKInbound; then
    csrk_inbound=$(registry_hex "$hive" "$device_path" CSRKInbound | extract_hexdump)
  fi

  debug "BLE device $(format_mac_colon "$windows_mac"): LTK=${ltk:-<missing>} KeyLength=${key_length:-<missing>} EDIV=${ediv:-<missing>} ERandHex=${erand_hex:-<missing>} Rand=${rand:-<missing>} IRK=${irk:-<missing>} CSRK=${csrk:-<missing>} CSRKInbound=${csrk_inbound:-<missing>}"

  [[ -n $ltk && -n $key_length && -n $ediv ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): missing required BLE values in Windows registry")
    return 0
  }

  if ! source_path=$(resolve_linux_device_path "$windows_mac"); then
    return 0
  fi

  if ! final_path=$(prepare_linux_device_path "$windows_mac" "$source_path"); then
    return 0
  fi

  debug "BLE device $(format_mac_colon "$windows_mac"): using Linux path $final_path"

  info_file="$final_path/info"
  [[ -f $info_file ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): missing Linux info file at $info_file")
    return 0
  }

  backup_info_file "$info_file"
  update_info_file "$info_file" ble '' "$ltk" "$key_length" "$ediv" "$rand" "$irk" "$csrk" "$csrk_inbound"
  UPDATED_DEVICES+=("$(device_label "$windows_mac"): updated BLE keys from Windows")
}

process_windows_devices() {
  local hive=$1
  local adapter_path=$2
  local adapter_ls value_name device_name_raw device_mac

  adapter_ls=$(registry_ls "$hive" "$adapter_path")

  while read -r value_name; do
    [[ -n $value_name ]] || continue
    device_mac=$(normalize_mac_nosep "$value_name")
    if [[ $device_mac =~ ^[0-9A-F]{12}$ ]]; then
      process_classic_device "$hive" "$adapter_path" "$value_name"
    fi
  done < <(printf '%s\n' "$adapter_ls" | parse_value_names)

  while read -r device_name_raw; do
    [[ -n $device_name_raw ]] || continue
    device_mac=$(normalize_mac_nosep "$device_name_raw")
    [[ $device_mac =~ ^[0-9A-F]{12}$ ]] || continue
    process_ble_device "$hive" "$adapter_path\\$device_name_raw" "$device_name_raw"
  done < <(printf '%s\n' "$adapter_ls" | parse_subkeys)
}

sync_linux_classic_device_to_windows() {
  local hive=$1
  local adapter_path=$2
  local windows_registry_name=$3
  local windows_mac source_path info_file link_key reg_value

  windows_mac=$(normalize_mac_nosep "$windows_registry_name")

  if ! source_path=$(resolve_linux_device_path "$windows_mac"); then
    return 0
  fi

  info_file="$source_path/info"
  [[ -f $info_file ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): missing Linux info file at $info_file")
    return 0
  }

  eval "$(extract_linux_device_material "$info_file")"

  [[ $DEVICE_KIND == "classic" && $LINK_KEY =~ ^[0-9A-F]{32}$ ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): Linux info file does not contain a usable classic LinkKey")
    return 0
  }

  ensure_windows_hive_backup "$hive"
  reg_value=$(hex_to_reg_binary "$LINK_KEY") || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): failed to convert Linux LinkKey for Windows registry")
    return 0
  }
  registry_import_values "$hive" "$adapter_path" "\"$windows_registry_name\"=$reg_value"
  UPDATED_DEVICES+=("$(device_label "$windows_mac"): updated Windows classic pairing key from Linux")
}

sync_linux_ble_device_to_windows() {
  local hive=$1
  local device_path=$2
  local windows_registry_name=$3
  local windows_mac source_path info_file ltk_value irk_value csrk_value csrk_inbound_value
  local -a reg_lines=()

  windows_mac=$(normalize_mac_nosep "$windows_registry_name")

  if ! source_path=$(resolve_linux_device_path "$windows_mac"); then
    return 0
  fi

  info_file="$source_path/info"
  [[ -f $info_file ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): missing Linux info file at $info_file")
    return 0
  }

  eval "$(extract_linux_device_material "$info_file")"

  [[ $DEVICE_KIND == "ble" && $LTK =~ ^[0-9A-F]{32}$ && $ENC_SIZE =~ ^[0-9]+$ && $EDIV =~ ^[0-9]+$ && $RAND =~ ^[0-9]+$ ]] || {
    SKIPPED_DEVICES+=("$(format_mac_colon "$windows_mac"): Linux info file does not contain complete BLE key material")
    return 0
  }

  ltk_value=$(hex_to_reg_binary "$LTK")
  reg_lines+=("\"LTK\"=$ltk_value")
  reg_lines+=("\"KeyLength\"=$(decimal_to_reg_dword "$ENC_SIZE")")
  reg_lines+=("\"EDIV\"=$(decimal_to_reg_dword "$EDIV")")
  reg_lines+=("\"ERand\"=$(decimal_to_reg_qword "$RAND")")

  if [[ $IRK =~ ^[0-9A-F]{32}$ ]]; then
    irk_value=$(hex_to_reg_binary "$IRK")
    reg_lines+=("\"IRK\"=$irk_value")
  fi

  if [[ $CSRK =~ ^[0-9A-F]{32}$ ]]; then
    csrk_value=$(hex_to_reg_binary "$CSRK")
    reg_lines+=("\"CSRK\"=$csrk_value")
  fi

  if [[ $CSRK_INBOUND =~ ^[0-9A-F]{32}$ ]]; then
    csrk_inbound_value=$(hex_to_reg_binary "$CSRK_INBOUND")
    reg_lines+=("\"CSRKInbound\"=$csrk_inbound_value")
  fi

  ensure_windows_hive_backup "$hive"
  registry_import_values "$hive" "$device_path" "${reg_lines[@]}"
  UPDATED_DEVICES+=("$(device_label "$windows_mac"): updated Windows BLE keys from Linux")
}

process_linux_devices_to_windows() {
  local hive=$1
  local adapter_path=$2
  local adapter_ls value_name device_name_raw device_mac

  adapter_ls=$(registry_ls "$hive" "$adapter_path")

  while read -r value_name; do
    [[ -n $value_name ]] || continue
    device_mac=$(normalize_mac_nosep "$value_name")
    if [[ $device_mac =~ ^[0-9A-F]{12}$ ]]; then
      sync_linux_classic_device_to_windows "$hive" "$adapter_path" "$value_name"
    fi
  done < <(printf '%s\n' "$adapter_ls" | parse_value_names)

  while read -r device_name_raw; do
    [[ -n $device_name_raw ]] || continue
    device_mac=$(normalize_mac_nosep "$device_name_raw")
    [[ $device_mac =~ ^[0-9A-F]{12}$ ]] || continue
    sync_linux_ble_device_to_windows "$hive" "$adapter_path\\$device_name_raw" "$device_name_raw"
  done < <(printf '%s\n' "$adapter_ls" | parse_subkeys)
}

print_summary() {
  local entry

  printf '\nUpdated devices:\n'
  if [[ ${#UPDATED_DEVICES[@]} -eq 0 ]]; then
    printf '  none\n'
  else
    for entry in "${UPDATED_DEVICES[@]}"; do
      printf '  - %s\n' "$entry"
    done
  fi

  printf '\nSkipped devices:\n'
  if [[ ${#SKIPPED_DEVICES[@]} -eq 0 ]]; then
    printf '  none\n'
  else
    for entry in "${SKIPPED_DEVICES[@]}"; do
      printf '  - %s\n' "$entry"
    done
  fi
}

main() {
  local selected_partition system_hive controller_mac controller_dir
  local control_set keys_path windows_adapter adapter_path

  parse_args "$@"
  require_root
  require_commands

  TMP_ROOT=$(mktemp -d /tmp/sync-bluetooth-keys.XXXXXX)

  discover_windows_partitions
  selected_partition=$(select_windows_partition)
  debug "Selected Windows partition: $selected_partition"
  mount_selected_partition "$selected_partition"

  system_hive="$SELECTED_MOUNT/Windows/System32/config/SYSTEM"
  [[ -f $system_hive ]] || die "Mounted partition does not contain a Windows SYSTEM hive."

  control_set=$(get_current_control_set "$system_hive")
  keys_path="\\$control_set\\Services\\BTHPORT\\Parameters\\Keys"

  controller_mac=$(get_local_controller_mac)
  controller_dir="/var/lib/bluetooth/$controller_mac"
  load_linux_devices "$controller_dir"

  windows_adapter=$(choose_windows_adapter "$system_hive" "$keys_path" "$controller_mac")
  adapter_path="$keys_path\\$windows_adapter"
  debug "Using Windows Bluetooth adapter: $(format_mac_colon "$windows_adapter" 2>/dev/null || printf '%s' "$windows_adapter")"

  if [[ $SYNC_DIRECTION == "linux-to-windows" ]]; then
    process_linux_devices_to_windows "$system_hive" "$adapter_path"
  else
    process_windows_devices "$system_hive" "$adapter_path"
  fi

  if [[ ${#UPDATED_DEVICES[@]} -gt 0 ]]; then
    if [[ $SYNC_DIRECTION == "linux-to-windows" ]]; then
      log "Updated Windows registry entries"
    else
      log "Restarting bluetooth.service"
      systemctl restart bluetooth.service
    fi
  else
    if [[ $SYNC_DIRECTION == "linux-to-windows" ]]; then
      log "No devices were updated; Windows registry was not modified"
    else
      log "No devices were updated; bluetooth.service was not restarted"
    fi
  fi

  print_summary
}

main "$@"
