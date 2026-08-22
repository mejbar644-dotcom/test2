#!/usr/bin/env bash
# ============================================================
# AmneziaWG Stable Iran <-> Foreign Tunnel
# Debian / Ubuntu - nftables - systemd - no unsafe rotation
# ============================================================

set -Eeuo pipefail
umask 077

IFACE="awg0"
CFG_DIR="/etc/amnezia/amneziawg"
CFG="${CFG_DIR}/${IFACE}.conf"
META="${CFG_DIR}/${IFACE}.meta"
FW_HELPER="/usr/local/sbin/awg-nft"
IR_ADDR="10.77.0.2"
FR_ADDR="10.77.0.1"
CIDR="30"
DEFAULT_KEEP_TCP="22,80,443,10052"

info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root."

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

default_nic() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

public_ip() {
  curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true
}

valid_ipv4() {
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' <<< "$ip"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

rand_between() {
  local min=$1 max=$2
  shuf -i "${min}-${max}" -n 1
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  info "Installing base packages..."
  apt-get update -qq
  apt-get install -y -qq \
    curl ca-certificates nftables iproute2 \
    systemd-timesyncd chrony >/dev/null

  if ! command -v awg >/dev/null 2>&1; then
    info "Installing AmneziaWG..."
    . /etc/os-release

    if [[ "${ID:-}" == "ubuntu" ]]; then
      apt-get install -y -qq software-properties-common >/dev/null
      add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || true
      apt-get update -qq
    fi

    apt-get install -y -qq amneziawg amneziawg-tools >/dev/null 2>&1 \
      || die "Could not install AmneziaWG packages. Install awg and awg-quick, then run again."
  fi

  need_cmd awg
  need_cmd awg-quick
  need_cmd nft
  need_cmd ip
  need_cmd shuf

  systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
  systemctl enable --now chrony >/dev/null 2>&1 || true
}

write_sysctl() {
  cat > /etc/sysctl.d/99-amneziawg-tunnel.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.tcp_mtu_probing=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
}

# Profile is generated only once on FOREIGN and distributed in token.
# This prevents two sides from desynchronizing after a timed "rotation".
generate_profile() {
  JC=$(rand_between 4 10)
  JMIN=$(rand_between 64 160)
  JMAX=$(rand_between "$((JMIN + 128))" 768)

  S1=$(rand_between 15 63)
  S2=$(rand_between 15 63)
  while [[ "$S2" == "$S1" ]]; do
    S2=$(rand_between 15 63)
  done
  S3=$(rand_between 15 63)
  S4=$(rand_between 15 31)

  H1=$(rand_between 100000 2000000000)
  H2=$(rand_between 100000 2000000000)
  H3=$(rand_between 100000 2000000000)
  H4=$(rand_between 100000 2000000000)

  while [[ "$H2" == "$H1" ]]; do H2=$(rand_between 100000 2000000000); done
  while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3=$(rand_between 100000 2000000000); done
  while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4=$(rand_between 100000 2000000000); done
}

encode_token() {
  printf '%s|' \
    "v7" "$FOREIGN_IP" "$AWG_PORT" "$FR_PUB" "$PSK" \
    "$JC" "$JMIN" "$JMAX" "$S1" "$S2" "$S3" "$S4" \
    "$H1" "$H2" "$H3" "$H4" \
    | base64 -w0
}

decode_token() {
  local raw
  raw=$(printf '%s' "$1" | tr -d '[:space:]' | base64 -d 2>/dev/null) \
    || die "Invalid token."

  IFS='|' read -r VERSION FOREIGN_IP AWG_PORT FR_PUB PSK \
    JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 _ <<< "$raw"

  [[ "$VERSION" == "v7" ]] || die "This script accepts only v7 tokens."
  valid_ipv4 "$FOREIGN_IP" || die "Invalid foreign IP in token."
  valid_port "$AWG_PORT" || die "Invalid port in token."
  [[ -n "$FR_PUB" && -n "$PSK" ]] || die "Incomplete token."
}

write_fw_helper() {
  cat > "$FW_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
ROLE="${2:-}"
NIC="${3:-}"
IFACE="${4:-}"
AWG_PORT="${5:-}"
KEEP_TCP="${6:-}"
IR_ADDR="${7:-}"

delete_rules() {
  nft delete table ip awg_tunnel 2>/dev/null || true
  nft delete table inet awg_tunnel 2>/dev/null || true
}

case "$ACTION:$ROLE" in
  down:*)
    delete_rules
    exit 0
    ;;

  up:iran)
    delete_rules

    nft -f - <<EOF_NFT
table ip awg_tunnel {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$NIC" tcp dport != { $KEEP_TCP } dnat to 10.77.0.1
    iifname "$NIC" udp dport != $AWG_PORT dnat to 10.77.0.1
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$IFACE" masquerade
  }
}

table inet awg_tunnel {
  chain forward_filter {
    type filter hook forward priority filter; policy accept;
    iifname "$NIC" oifname "$IFACE" accept
    iifname "$IFACE" oifname "$NIC" ct state established,related accept
  }

  chain forward_mangle {
    type filter hook forward priority mangle; policy accept;
    tcp flags syn tcp option maxseg size set rt mtu
  }
}
EOF_NFT
    ;;

  up:foreign)
    delete_rules

    nft -f - <<EOF_NFT
table ip awg_tunnel {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $IR_ADDR oifname "$NIC" masquerade
  }
}

table inet awg_tunnel {
  chain forward_filter {
    type filter hook forward priority filter; policy accept;
    iifname "$IFACE" oifname "$NIC" accept
    iifname "$NIC" oifname "$IFACE" ct state established,related accept
  }

  chain forward_mangle {
    type filter hook forward priority mangle; policy accept;
    tcp flags syn tcp option maxseg size set rt mtu
  }
}
EOF_NFT
    ;;

  *)
    echo "Usage: $0 {up|down} {iran|foreign} NIC IFACE PORT KEEP_TCP IR_ADDR" >&2
    exit 1
    ;;
esac
EOF
  chmod 700 "$FW_HELPER"
}

common_interface() {
  cat <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${SELF_ADDR}/${CIDR}
ListenPort = ${AWG_PORT}
MTU = ${MTU}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
PostUp = ${FW_HELPER} up ${ROLE} ${NIC} %i ${AWG_PORT} ${KEEP_TCP_PORTS} ${IR_ADDR}
PostDown = ${FW_HELPER} down ${ROLE} ${NIC} %i ${AWG_PORT} ${KEEP_TCP_PORTS} ${IR_ADDR}
EOF
}

write_config() {
  mkdir -p "$CFG_DIR"
  chmod 700 "$CFG_DIR"

  {
    common_interface
    cat <<EOF

[Peer]
PublicKey = ${PEER_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${PEER_ALLOWED}
EOF

    if [[ "$ROLE" == "iran" ]]; then
      cat <<EOF
Endpoint = ${FOREIGN_IP}:${AWG_PORT}
PersistentKeepalive = 25
EOF
    fi
  } > "$CFG"

  chmod 600 "$CFG"
}

save_meta() {
  cat > "$META" <<EOF
ROLE=${ROLE}
NIC=${NIC}
AWG_PORT=${AWG_PORT}
MTU=${MTU}
KEEP_TCP_PORTS=${KEEP_TCP_PORTS}
EOF
  chmod 600 "$META"
}

bring_up() {
  systemctl disable --now "awg-quick@${IFACE}" >/dev/null 2>&1 || true
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  ip link delete "$IFACE" >/dev/null 2>&1 || true

  awg-quick up "$IFACE" || die "awg-quick failed. Check: journalctl -xe"

  systemctl enable "awg-quick@${IFACE}" >/dev/null 2>&1 || true
  ok "${IFACE} is up."
}

wait_handshake() {
  info "Waiting up to 30 seconds for a handshake..."
  for _ in $(seq 1 30); do
    if awg show "$IFACE" latest-handshakes 2>/dev/null \
      | awk '$2 > 0 {found=1} END {exit !found}'; then
      ok "Handshake established."
      return 0
    fi
    sleep 1
  done
  warn "No handshake yet. Verify foreign UDP port ${AWG_PORT}, provider firewall, and peer key."
  return 1
}

foreign_setup() {
  install_packages
  write_sysctl
  write_fw_helper

  ROLE="foreign"
  NIC=$(default_nic)
  [[ -n "$NIC" ]] || die "Could not detect default network interface."

  local detected
  detected=$(public_ip)
  read -rp "Foreign public IPv4 [${detected:-required}]: " FOREIGN_IP
  FOREIGN_IP="${FOREIGN_IP:-$detected}"
  valid_ipv4 "$FOREIGN_IP" || die "A valid public IPv4 is required."

  local default_port
  default_port=$(rand_between 20000 60000)
  read -rp "AWG UDP port [${default_port}]: " AWG_PORT
  AWG_PORT="${AWG_PORT:-$default_port}"
  valid_port "$AWG_PORT" || die "Invalid UDP port."

  read -rp "Tunnel MTU [1320]: " MTU
  MTU="${MTU:-1320}"
  [[ "$MTU" =~ ^[0-9]+$ ]] && (( MTU >= 1200 && MTU <= 1420 )) || die "MTU must be 1200-1420."

  KEEP_TCP_PORTS="$DEFAULT_KEEP_TCP"
  PSK=$(awg genpsk)
  generate_profile

  PRIV=$(awg genkey)
  FR_PUB=$(printf '%s' "$PRIV" | awg pubkey)

  # No Iran public key yet: write interface-only config.
  SELF_ADDR="$FR_ADDR"
  PEER_PUB="PLACEHOLDER"
  PEER_ALLOWED="${IR_ADDR}/32"

  mkdir -p "$CFG_DIR"
  {
    common_interface
  } > "$CFG"
  chmod 600 "$CFG"

  save_meta
  bring_up

  echo
  ok "Foreign side is ready."
  echo "Open UDP/${AWG_PORT} in your provider firewall/security group."
  echo
  echo "Copy this token securely to the Iran server:"
  echo
  encode_token
  echo
}

iran_setup() {
  install_packages
  write_sysctl
  write_fw_helper

  ROLE="iran"
  NIC=$(default_nic)
  [[ -n "$NIC" ]] || die "Could not detect default network interface."

  echo "Paste the token generated on the foreign server:"
  read -r -p "> " TOKEN
  decode_token "$TOKEN"

  read -rp "Tunnel MTU [1320]: " MTU
  MTU="${MTU:-1320}"
  [[ "$MTU" =~ ^[0-9]+$ ]] && (( MTU >= 1200 && MTU <= 1420 )) || die "MTU must be 1200-1420."

  read -rp "TCP ports that must remain on Iran server [${DEFAULT_KEEP_TCP}]: " KEEP_TCP_PORTS
  KEEP_TCP_PORTS="${KEEP_TCP_PORTS:-$DEFAULT_KEEP_TCP}"
  [[ "$KEEP_TCP_PORTS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Ports must look like: 22,80,443"

  PRIV=$(awg genkey)
  IR_PUB=$(printf '%s' "$PRIV" | awg pubkey)

  SELF_ADDR="$IR_ADDR"
  PEER_PUB="$FR_PUB"
  PEER_ALLOWED="${FR_ADDR}/32"

  write_config
  save_meta
  bring_up

  echo
  ok "Iran side is ready."
  echo "Paste this Iran public key on the foreign server, option 3:"
  echo
  echo "$IR_PUB"
  echo
}

add_iran_peer() {
  [[ -f "$CFG" && -f "$META" ]] || die "Run foreign setup first."
  grep -qx 'ROLE=foreign' "$META" || die "This host is not configured as foreign."

  read -rp "Iran public key: " IR_PUB
  [[ -n "$IR_PUB" ]] || die "Key is required."

  awk '/^\[Peer\]/{exit} {print}' "$CFG" > "${CFG}.new"

  PSK=$(awk -F' = ' '/^PresharedKey/{print $2; exit}' "$CFG" 2>/dev/null || true)
  if [[ -z "$PSK" ]]; then
    warn "PSK is not in foreign config yet; recovering it is impossible."
    die "Recreate the foreign side and generate a new token."
  fi

  cat >> "${CFG}.new" <<EOF

[Peer]
PublicKey = ${IR_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${IR_ADDR}/32
EOF

  mv "${CFG}.new" "$CFG"
  chmod 600 "$CFG"
  bring_up
  ok "Iran peer added. The tunnel should handshake shortly."
  wait_handshake || true
}

diagnostics() {
  echo "=== Interface ==="
  awg show "$IFACE" 2>/dev/null || true
  echo
  echo "=== Address / route ==="
  ip -4 addr show "$IFACE" 2>/dev/null || true
  ip -4 route get "$FR_ADDR" 2>/dev/null || true
  echo
  echo "=== Dedicated nftables rules ==="
  nft list table ip awg_tunnel 2>/dev/null || true
  nft list table inet awg_tunnel 2>/dev/null || true
  echo
  echo "=== Recent service logs ==="
  journalctl -u "awg-quick@${IFACE}" -n 40 --no-pager 2>/dev/null || true
}

uninstall_all() {
  systemctl disable --now "awg-quick@${IFACE}" >/dev/null 2>&1 || true
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  ip link delete "$IFACE" >/dev/null 2>&1 || true
  "$FW_HELPER" down any any "$IFACE" 0 0 "$IR_ADDR" 2>/dev/null || true

  rm -rf "$CFG_DIR"
  rm -f "$FW_HELPER" /etc/sysctl.d/99-amneziawg-tunnel.conf
  sysctl --system >/dev/null 2>&1 || true
  ok "AmneziaWG tunnel configuration and dedicated nftables rules removed."
}

echo
echo "AmneziaWG Stable Tunnel (nftables)"
echo "1) Configure Iran server      (run after foreign)"
echo "2) Configure foreign server   (run first)"
echo "3) Foreign: add Iran peer public key"
echo "4) Diagnostics"
echo "5) Uninstall tunnel"
echo

read -r -p "Choice: " CHOICE

case "$CHOICE" in
  1) iran_setup ;;
  2) foreign_setup ;;
  3) add_iran_peer ;;
  4) diagnostics ;;
  5) uninstall_all ;;
  *) die "Invalid choice." ;;
esac
