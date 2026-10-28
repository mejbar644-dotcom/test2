#!/usr/bin/env bash
# ============================================================
#  Netplas - AmneziaWG Anti-Filter Tunnel v5.0 (Iran <-> Foreign)
#
#  Changes vs v4.2:
#   - Real AmneziaWG 2.0 profile: H1-H4 as non-overlapping RANGES,
#     I1 handshake mimicry (QUIC-like / DNS-like), S1-S4, Jc/Jmin/Jmax
#   - Automatic fallback to the legacy (1.x) profile when the installed
#     AmneziaWG rejects the 2.0 syntax (or force it: FORCE_LEGACY=1)
#   - Iran side uses its own random ListenPort (src port != dst port)
#   - Forwarding mode: all-but-keep / only listed ports / none
#   - SSH port auto-protected, install log + version report
#   - Option 3 adds the Iran peer LIVE (awg set), no tunnel restart
#
#  NOTE: tokens are v5 and NOT compatible with v4.2. Uninstall the
#  old setup (option 5) on both servers before installing this one.
# ============================================================

set -uo pipefail

IFACE="awg0"
CFG_DIR="/etc/amnezia/amneziawg"
CFG="${CFG_DIR}/${IFACE}.conf"
META="${CFG_DIR}/${IFACE}.meta"
LOG="/var/log/netplas-install.log"
IR_ADDR="10.0.0.2"
FR_ADDR="10.0.0.1"
CIDR="30"
DEF_KEEP_TCP="22,80,443,10052"   # TCP ports that must stay on the Iran server

# ---------- colors (safe when TERM is unset) ----------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
  CYAN=$(tput setaf 6); YELLOW=$(tput setaf 3); GREEN=$(tput setaf 2)
  RED=$(tput setaf 1); BOLD=$(tput bold); RESET=$(tput sgr0)
else
  CYAN=""; YELLOW=""; GREEN=""; RED=""; BOLD=""; RESET=""
fi
info()  { echo "${CYAN}[*]${RESET} $*"; }
ok()    { echo "${GREEN}[+]${RESET} $*"; }
warn()  { echo "${YELLOW}[!]${RESET} $*"; }
err()   { echo "${RED}[x]${RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

banner() {
  echo "${CYAN}${BOLD}"
  echo "===================================="
  echo "          GitHub: Netplas"
  echo "  AmneziaWG Anti-Filter Tunnel v5.0"
  echo "===================================="
  echo "${RESET}"
}

# ---------- helpers ----------
rnd() { # rnd MIN MAX -> random integer in [MIN, MAX]
  local min=$1 max=$2 span=$(( $2 - $1 + 1 ))
  echo $(( min + ( $(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % span ) ))
}

main_iface() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

pub_ip() { curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true; }

udp_port_busy() {
  ss -Hulnp 2>/dev/null | awk -v p="$1" '$4 ~ (":" p "$") {f=1} END{exit !f}'
}

ssh_ports() {
  ss -Htlnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -un | paste -sd, -
}

merge_ports() { # merge_ports "a,b" "c,d" -> unique, comma separated
  printf '%s\n' "$@" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -
}

# ---------- install ----------
detect_os() {
  . /etc/os-release 2>/dev/null || true
  OS_ID="${ID:-unknown}"
}

show_versions() {
  local tools kmod
  tools=$(awg --version 2>/dev/null | head -n1 || true)
  kmod=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2}')
  info "awg tools : ${tools:-unknown}"
  if [[ -n "$kmod" ]]; then info "kernel mod: ${kmod}"; fi
  if command -v amneziawg-go >/dev/null 2>&1; then
    info "userspace : $(amneziawg-go --version 2>/dev/null | head -n1 || echo amneziawg-go)"
  fi
  warn "Both servers MUST run versions that support the same profile (compare these lines)."
}

install_tools() {
  detect_os
  info "Installing prerequisites (log: ${LOG})..."
  export DEBIAN_FRONTEND=noninteractive
  : > "$LOG"
  apt-get update -qq >>"$LOG" 2>&1
  apt-get install -y -qq curl wget git iptables iproute2 openresolv \
      software-properties-common ca-certificates build-essential \
      "linux-headers-$(uname -r)" >>"$LOG" 2>&1 || \
  apt-get install -y -qq curl wget git iptables iproute2 \
      software-properties-common ca-certificates build-essential >>"$LOG" 2>&1

  if [[ "$OS_ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >>"$LOG" 2>&1 || warn "PPA unreachable (see ${LOG})."
    apt-get update -qq >>"$LOG" 2>&1
    apt-get install -y -qq amneziawg amneziawg-tools >>"$LOG" 2>&1 || warn "amneziawg package install failed (see ${LOG})."
  fi

  if ! command -v awg >/dev/null 2>&1; then
    warn "Package not available; building amneziawg-tools from source..."
    rm -rf /tmp/awg-tools
    git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-tools /tmp/awg-tools >>"$LOG" 2>&1 \
      || die "Cannot fetch amneziawg-tools (GitHub unreachable from this server?). See ${LOG}."
    make -s -C /tmp/awg-tools/src -j"$(nproc)" >>"$LOG" 2>&1 \
      && make -s -C /tmp/awg-tools/src install >>"$LOG" 2>&1 \
      || die "Build of amneziawg-tools failed. See ${LOG}."
  fi
  command -v awg >/dev/null 2>&1 || die "'awg' still not found."
  ok "amneziawg-tools ready ($(command -v awg))."
}

kernel_ok() {
  modprobe amneziawg >/dev/null 2>&1
  ip link add dev awgtest type amneziawg >/dev/null 2>&1 || return 1
  ip link del awgtest >/dev/null 2>&1
  return 0
}

install_userspace() {
  if command -v amneziawg-go >/dev/null 2>&1; then ok "amneziawg-go already installed."; return 0; fi
  warn "Kernel module unavailable (LXC/OpenVZ?). Installing amneziawg-go..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq golang-go >>"$LOG" 2>&1 || apt-get install -y -qq golang >>"$LOG" 2>&1
  command -v go >/dev/null 2>&1 || die "Go toolchain not available."
  rm -rf /tmp/awg-go
  git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-go /tmp/awg-go >>"$LOG" 2>&1 \
    || die "Cannot fetch amneziawg-go."
  ( cd /tmp/awg-go && go build -o /usr/local/bin/amneziawg-go . ) >>"$LOG" 2>&1 \
    || die "Build of amneziawg-go failed. See ${LOG}."
  chmod +x /usr/local/bin/amneziawg-go
  [[ -e /dev/net/tun ]] || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null; chmod 600 /dev/net/tun; }
  ok "amneziawg-go installed."
}

setup_backend() {
  if kernel_ok; then
    ok "Kernel module 'amneziawg' works."
    echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
    USERSPACE=0
  else
    install_userspace
    USERSPACE=1
  fi
  mkdir -p /etc/default
  if [[ $USERSPACE -eq 1 ]]; then
    cat > /etc/default/amneziawg <<'EOF'
WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
AWG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
WG_SUDO=1
EOF
  else
    : > /etc/default/amneziawg
  fi
  show_versions
}

# ---------- obfuscation profiles ----------
# AmneziaWG 2.0: S1-S4 padding, H1-H4 as ranges, optional I1 mimicry packet
gen_profile_v2() {
  PMODE="v2"
  JC=$(rnd 3 8)
  JMIN=$(rnd 40 90)
  JMAX=$(rnd $((JMIN + 60)) 900)

  S1=$(rnd 15 140); S2=$(rnd 15 140)
  while [[ $((S1 + 56)) -eq $S2 ]]; do S2=$(rnd 15 140); done
  S3=$(rnd 10 60)
  S4=$(rnd 4 24)

  # Four NON-overlapping ranges: one per ~1e9 bucket, bucket order shuffled.
  local order=(0 1 2 3) i j t b lo hi
  local hs=()
  for i in 3 2 1; do
    j=$(rnd 0 "$i"); t=${order[$i]}; order[$i]=${order[$j]}; order[$j]=$t
  done
  for i in 0 1 2 3; do
    b=${order[$i]}
    lo=$(( b * 1000000000 + $(rnd 100 300000000) ))
    hi=$(( lo + $(rnd 1000000 600000000) ))
    hs[$i]="${lo}-${hi}"
  done
  H1=${hs[0]}; H2=${hs[1]}; H3=${hs[2]}; H4=${hs[3]}
}

# Legacy 1.x profile: single integer H values, no S3/S4/I1
gen_profile_legacy() {
  PMODE="legacy"
  JC=$(rnd 3 8)
  JMIN=$(rnd 40 90)
  JMAX=$(rnd $((JMIN + 60)) 900)
  S1=$(rnd 15 140); S2=$(rnd 15 140)
  while [[ $((S1 + 56)) -eq $S2 ]]; do S2=$(rnd 15 140); done
  S3=""; S4=""; I1=""
  H1=$(rnd 100000 2147483000); H2=$(rnd 100000 2147483000)
  H3=$(rnd 100000 2147483000); H4=$(rnd 100000 2147483000)
  while [[ "$H2" == "$H1" ]]; do H2=$(rnd 100000 2147483000); done
  while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3=$(rnd 100000 2147483000); done
  while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4=$(rnd 100000 2147483000); done
}

# I1 = signature packet sent before the handshake (initiator side)
gen_i1() {
  case "$1" in
    quic) I1="<b 0xc00000000108><r 8><b 0x08><r 8><b 0x00><r $(rnd 600 900)>" ;;
    dns)  I1="<r 2><b 0x01000001000000000000><b 0x0377777706676f6f676c6503636f6d00><b 0x00010001>" ;;
    *)    I1="" ;;
  esac
}

encode_token() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "v5" "$FOREIGN_IP" "$AWG_PORT" "$FR_PUB" "$PSK" \
    "$JC" "$JMIN" "$JMAX" "$S1" "$S2" "${S3:--}" "${S4:--}" \
    "$H1" "$H2" "$H3" "$H4" "${I1:--}" "$PMODE" \
    | base64 -w0
}

decode_token() {
  local raw v
  raw=$(echo "$1" | tr -d ' \n\r' | base64 -d 2>/dev/null) || die "Invalid token."
  IFS='|' read -r V FOREIGN_IP AWG_PORT FR_PUB PSK JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 I1 PMODE <<< "$raw"
  [[ "$V" == "v5" ]] || die "Token version mismatch (need v5). Re-run option 2 on the foreign server."
  [[ -n "$FR_PUB" && -n "$AWG_PORT" && -n "$PMODE" ]] || die "Token is incomplete."
  for v in S3 S4 I1; do
    if [[ "${!v}" == "-" ]]; then printf -v "$v" ''; fi
  done
}

# ---------- config writers ----------
common_iface_block() {
  cat <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${SELF_ADDR}/${CIDR}
ListenPort = ${LISTEN_PORT}
MTU = ${MTU}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
EOF
  if [[ "$PMODE" == "v2" ]]; then
    echo "S3 = ${S3}"
    echo "S4 = ${S4}"
  fi
  cat <<EOF
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
EOF
  if [[ "$PMODE" == "v2" && -n "${I1:-}" ]]; then
    echo "I1 = ${I1}"
  fi
}

write_iran_cfg() {
  local NIC=$1 dnat="" flush="" tail_down=""
  case "$FWD_MODE" in
    all)
      dnat+="PostUp = iptables -t nat -A AWG_DNAT -p tcp -m multiport ! --dports ${KEEP_TCP} -j DNAT --to-destination ${FR_ADDR}"$'\n'
      dnat+="PostUp = iptables -t nat -A AWG_DNAT -p udp -m multiport ! --dports ${UDP_EXCL} -j DNAT --to-destination ${FR_ADDR}"$'\n'
      ;;
    list)
      if [[ -n "$FWD_TCP" ]]; then
        dnat+="PostUp = iptables -t nat -A AWG_DNAT -p tcp -m multiport --dports ${FWD_TCP} -j DNAT --to-destination ${FR_ADDR}"$'\n'
      fi
      if [[ -n "$FWD_UDP" ]]; then
        dnat+="PostUp = iptables -t nat -A AWG_DNAT -p udp -m multiport --dports ${FWD_UDP} -j DNAT --to-destination ${FR_ADDR}"$'\n'
      fi
      ;;
  esac
  if [[ "$FWD_MODE" != "none" ]]; then
    flush="PostUp = iptables -t nat -F AWG_DNAT"$'\n'
    tail_down="PostDown = iptables -t nat -F AWG_DNAT 2>/dev/null || true"$'\n'
    tail_down+="PostDown = iptables -t nat -X AWG_DNAT 2>/dev/null || true"$'\n'
  fi

  mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
  {
    common_iface_block
    cat <<EOF
PostUp = sysctl -qw net.ipv4.ip_forward=1
PostUp = iptables -t nat -N AWG_DNAT 2>/dev/null || true
EOF
    printf '%s' "$flush"
    cat <<EOF
PostUp = iptables -t nat -C PREROUTING -i ${NIC} -j AWG_DNAT 2>/dev/null || iptables -t nat -I PREROUTING 1 -i ${NIC} -j AWG_DNAT
EOF
    printf '%s' "$dnat"
    cat <<EOF
PostUp = iptables -t nat -C POSTROUTING -o %i -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = iptables -C FORWARD -i ${NIC} -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${NIC} -o %i -j ACCEPT
PostUp = iptables -C FORWARD -i %i -o ${NIC} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -o ${NIC} -j ACCEPT
PostUp = iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t nat -D PREROUTING -i ${NIC} -j AWG_DNAT 2>/dev/null || true
EOF
    printf '%s' "$tail_down"
    cat <<EOF
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${NIC} -o %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -o ${NIC} -j ACCEPT 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

[Peer]
PublicKey = ${FR_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${FR_ADDR}/32
Endpoint = ${FOREIGN_IP}:${AWG_PORT}
PersistentKeepalive = 25
EOF
  } > "$CFG"
  chmod 600 "$CFG"
}

write_foreign_cfg() {
  local NIC=$1
  mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
  { common_iface_block
    cat <<EOF
PostUp = sysctl -qw net.ipv4.ip_forward=1
PostUp = iptables -C INPUT -p udp --dport ${AWG_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${AWG_PORT} -j ACCEPT
PostUp = iptables -C INPUT -i %i -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i %i -j ACCEPT
PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -j ACCEPT
PostUp = iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o %i -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${IR_ADDR}/32 -o ${NIC} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${IR_ADDR}/32 -o ${NIC} -j MASQUERADE
PostUp = iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D INPUT -p udp --dport ${AWG_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${IR_ADDR}/32 -o ${NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
EOF
    if [[ -n "${IR_PUB:-}" ]]; then
      cat <<EOF

[Peer]
PublicKey = ${IR_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${IR_ADDR}/32
PersistentKeepalive = 25
EOF
    fi
  } > "$CFG"
  chmod 600 "$CFG"
}

save_foreign_meta() {
  {
    echo "ROLE=foreign"; echo "NIC=${NIC}"; echo "PORT=${AWG_PORT}"; echo "MTU=${MTU}"
    echo "PSK=${PSK}"; echo "PMODE=${PMODE}"
    echo "TOKEN=$(encode_token)"
  } > "$META"; chmod 600 "$META"
}

# returns 0 on success, 1 on failure (caller decides what to do)
bring_up() {
  set -a; . /etc/default/amneziawg 2>/dev/null || true; set +a
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  ip link del "$IFACE" >/dev/null 2>&1 || true
  if ! awg-quick up "$IFACE"; then
    return 1
  fi
  if [[ -f /usr/lib/systemd/system/awg-quick@.service || -f /lib/systemd/system/awg-quick@.service ]]; then
    mkdir -p "/etc/systemd/system/awg-quick@${IFACE}.service.d"
    cat > "/etc/systemd/system/awg-quick@${IFACE}.service.d/override.conf" <<'EOF'
[Service]
EnvironmentFile=-/etc/default/amneziawg
Restart=on-failure
RestartSec=5
EOF
    systemctl daemon-reload
    systemctl enable "awg-quick@${IFACE}" >/dev/null 2>&1 && ok "Enabled on boot."
  fi
  ok "Interface ${IFACE} is up (profile: ${PMODE})."
  return 0
}

sysctl_tuning() {
  cat > /etc/sysctl.d/99-awg.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
EOF
  sysctl -q --system >/dev/null 2>&1 || true
}

wait_handshake() {
  info "Waiting for handshake (up to 25s)..."
  for _ in $(seq 1 25); do
    if awg show "$IFACE" latest-handshakes 2>/dev/null | awk '{if ($2+0 > 0) found=1} END{exit !found}'; then
      ok "Handshake established."
      return 0
    fi
    sleep 1
  done
  warn "No handshake yet. Check provider firewall for UDP port ${AWG_PORT} on the foreign server."
  return 1
}

# ============================ MENU ============================
main() {
  [[ $EUID -eq 0 ]] || die "Run this script as root."
  banner
  cat <<EOF
Select an option:
  1 - IRAN server      (run this AFTER the foreign server)
  2 - FOREIGN server   (run this FIRST)
  3 - FOREIGN: add / update the Iran peer key (live, no restart)
  4 - Diagnostics
  5 - Uninstall & clean up
EOF
  read -rp "Enter your choice: " CHOICE

  case "$CHOICE" in
  2)
    install_tools; setup_backend; sysctl_tuning
    NIC=$(main_iface); [[ -n "$NIC" ]] || die "Cannot detect default network interface."
    FOREIGN_IP=$(pub_ip)
    read -rp "Enter FOREIGN server public IP [${FOREIGN_IP:-none}]: " in_ip
    FOREIGN_IP=${in_ip:-$FOREIGN_IP}
    [[ -n "$FOREIGN_IP" ]] || die "Foreign IP is required."

    echo "Handshake mimicry (I1):"
    echo "  1 - QUIC-like  (recommended, default port UDP 443)"
    echo "  2 - DNS-like   (default port UDP 53)"
    echo "  3 - none       (random high port)"
    read -rp "Choice [1]: " MIM; MIM=${MIM:-1}
    case "$MIM" in
      2) gen_i1 dns;  DEF_PORT=53 ;;
      3) gen_i1 none; DEF_PORT=$(rnd 20000 60000) ;;
      *) gen_i1 quic; DEF_PORT=443 ;;
    esac
    if udp_port_busy "$DEF_PORT"; then
      warn "UDP ${DEF_PORT} is already in use on this server; picking a random port instead."
      DEF_PORT=$(rnd 20000 60000)
    fi
    read -rp "AmneziaWG UDP port [${DEF_PORT}]: " AWG_PORT
    AWG_PORT=${AWG_PORT:-$DEF_PORT}
    udp_port_busy "$AWG_PORT" && warn "UDP ${AWG_PORT} looks busy - the tunnel may fail to start."
    read -rp "Tunnel MTU [1320]: " MTU; MTU=${MTU:-1320}

    if [[ "${FORCE_LEGACY:-0}" == "1" ]]; then gen_profile_legacy; else
      I1_SAVE="$I1"; gen_profile_v2; I1="$I1_SAVE"
    fi
    PRIV=$(awg genkey); FR_PUB=$(echo "$PRIV" | awg pubkey); PSK=$(awg genpsk)
    SELF_ADDR="$FR_ADDR"; IR_PUB=""; LISTEN_PORT="$AWG_PORT"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow "${AWG_PORT}/udp" >/dev/null 2>&1 && ok "ufw: allowed ${AWG_PORT}/udp"
    fi

    write_foreign_cfg "$NIC"; save_foreign_meta
    if ! bring_up; then
      if [[ "$PMODE" == "v2" ]]; then
        warn "The installed AmneziaWG rejected the 2.0 profile. Falling back to the legacy (1.x) profile."
        warn "Obfuscation will be weaker. Update amneziawg on this server and re-run to get 2.0."
        gen_profile_legacy
        write_foreign_cfg "$NIC"; save_foreign_meta
        bring_up || die "awg-quick failed even with the legacy profile. See the error above."
      else
        die "awg-quick failed to start ${IFACE}."
      fi
    fi

    echo
    ok "Foreign server configured (profile: ${PMODE})."
    echo "${YELLOW}${BOLD}Copy this ONE token and paste it on the Iran server (option 1):${RESET}"
    echo "${CYAN}$(encode_token)${RESET}"
    echo
    ;;

  1)
    install_tools; setup_backend; sysctl_tuning
    NIC=$(main_iface); [[ -n "$NIC" ]] || die "Cannot detect default network interface."
    echo "Paste the token printed by the FOREIGN server:"
    read -rp "> " TOKEN
    decode_token "$TOKEN"
    read -rp "Tunnel MTU [1320]: " MTU; MTU=${MTU:-1320}

    echo "Which traffic arriving on this Iran server goes through the tunnel?"
    echo "  1 - ALL ports except a keep-list (classic behaviour)"
    echo "  2 - ONLY the ports I list"
    echo "  3 - Nothing yet (chain AWG_DNAT stays empty; add rules yourself / from your bot)"
    read -rp "Choice [2]: " FM; FM=${FM:-2}
    FWD_TCP=""; FWD_UDP=""; KEEP_TCP=""; UDP_EXCL=""
    LISTEN_PORT=$(rnd 30000 60000)
    while [[ "$LISTEN_PORT" == "$AWG_PORT" ]] || udp_port_busy "$LISTEN_PORT"; do LISTEN_PORT=$(rnd 30000 60000); done
    case "$FM" in
      1)
        FWD_MODE="all"
        read -rp "TCP ports to KEEP on this server [${DEF_KEEP_TCP}]: " kp
        KEEP_TCP=$(merge_ports "${kp:-$DEF_KEEP_TCP}" "$(ssh_ports)")
        read -rp "UDP ports to KEEP on this server [none]: " ku
        UDP_EXCL=$(merge_ports "$LISTEN_PORT" "${ku:-}")
        info "Kept TCP: ${KEEP_TCP} | Kept UDP: ${UDP_EXCL}"
        ;;
      3)
        FWD_MODE="none"
        ;;
      *)
        FWD_MODE="list"
        echo "Ports format: 2000,2001,3000:3100  (iptables multiport: max 15 entries, a range counts as 2)"
        read -rp "TCP ports to forward to the foreign server [none]: " FWD_TCP
        read -rp "UDP ports to forward to the foreign server [none]: " FWD_UDP
        FWD_UDP=$(printf '%s' "$FWD_UDP" | tr ',' '\n' | grep -vx "$LISTEN_PORT" | paste -sd, -)
        ;;
    esac

    PRIV=$(awg genkey); IR_PUB=$(echo "$PRIV" | awg pubkey)
    SELF_ADDR="$IR_ADDR"
    write_iran_cfg "$NIC"
    {
      echo "ROLE=iran"; echo "NIC=${NIC}"; echo "PORT=${AWG_PORT}"; echo "LISTEN=${LISTEN_PORT}"
      echo "MTU=${MTU}"; echo "FWD_MODE=${FWD_MODE}"; echo "PMODE=${PMODE}"
    } > "$META"
    chmod 600 "$META"
    bring_up || die "awg-quick failed. If the error mentions an unknown key (H1 range / I1 / S3 / S4) this server's AmneziaWG is too old for the 2.0 profile: update it, or re-run the foreign server with FORCE_LEGACY=1 to get a legacy token."

    echo
    ok "Iran server configured (profile: ${PMODE}, listen UDP ${LISTEN_PORT})."
    echo "${YELLOW}${BOLD}Iran public key -> paste it on the FOREIGN server (option 3):${RESET}"
    echo "${CYAN}${IR_PUB}${RESET}"
    echo
    wait_handshake || true
    ;;

  3)
    [[ -f "$CFG" ]] || die "No config at ${CFG}. Run option 2 first."
    read -rp "Enter IRAN server public key: " IR_PUB
    [[ -n "$IR_PUB" ]] || die "Key is required."
    PSK_LINE=$(sed -n 's/^PSK=//p' "$META" 2>/dev/null | head -n1)
    [[ -n "$PSK_LINE" ]] || PSK_LINE=$(awk '/^PresharedKey/{print $3; exit}' "$CFG")
    [[ -n "$PSK_LINE" ]] || die "Could not recover PresharedKey."
    OLD_PUB=$(awk '/^\[Peer\]/{p=1} p&&/^PublicKey/{print $3; exit}' "$CFG")

    # persist to the config file first
    awk '/^\[Peer\]/{exit} {print}' "$CFG" > "${CFG}.new"
    cat >> "${CFG}.new" <<EOF

[Peer]
PublicKey = ${IR_PUB}
PresharedKey = ${PSK_LINE}
AllowedIPs = ${IR_ADDR}/32
PersistentKeepalive = 25
EOF
    mv "${CFG}.new" "$CFG"; chmod 600 "$CFG"

    set -a; . /etc/default/amneziawg 2>/dev/null || true; set +a
    if awg show "$IFACE" >/dev/null 2>&1; then
      # live update: other peers/users are not interrupted
      if [[ -n "$OLD_PUB" && "$OLD_PUB" != "$IR_PUB" ]]; then
        awg set "$IFACE" peer "$OLD_PUB" remove 2>/dev/null || true
      fi
      awg set "$IFACE" peer "$IR_PUB" preshared-key <(printf '%s' "$PSK_LINE") \
          allowed-ips "${IR_ADDR}/32" persistent-keepalive 25 \
        || die "awg set failed."
      ok "Iran peer added live (no restart)."
    else
      PMODE=$(sed -n 's/^PMODE=//p' "$META" | head -n1); PMODE=${PMODE:-v2}
      bring_up || die "Start failed."
      ok "Interface was down; started with the new peer."
    fi
    ;;

  4)
    show_versions
    echo
    awg show "$IFACE" 2>/dev/null || echo "No device active."
    echo
    if [[ -f "$META" ]]; then
      ROLE_NOW=$(sed -n 's/^ROLE=//p' "$META" | head -n1)
      info "Role: ${ROLE_NOW} | profile: $(sed -n 's/^PMODE=//p' "$META" | head -n1)"
      if [[ "$ROLE_NOW" == "iran" ]]; then
        iptables -t nat -S AWG_DNAT 2>/dev/null || true
      else
        info "Token (for the Iran server):"
        sed -n 's/^TOKEN=//p' "$META"
      fi
    fi
    ;;

  5)
    systemctl disable --now "awg-quick@${IFACE}" >/dev/null 2>&1 || true
    awg-quick down "$IFACE" >/dev/null 2>&1 || true
    rm -rf "$CFG_DIR" "/etc/systemd/system/awg-quick@${IFACE}.service.d" \
           /etc/sysctl.d/99-awg.conf /etc/modules-load.d/amneziawg.conf
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "Cleaned up."
    ;;
  *)
    die "Invalid choice."
    ;;
  esac
}

# allow sourcing for tests; run the menu only when executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
