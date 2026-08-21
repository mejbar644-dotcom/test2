#!/usr/bin/env bash
# ============================================================
#  GitHub: Netplas
#  AmneziaWG Anti-Filter Tunnel v4.3 (Iran <-> Foreign)
#  - Added S3 & S4 Padding for AmneziaWG 2.0+
#  - Fully randomized profile & unique tokens on every run
#  - Optimized for TCP traffic flow & Anti-DPI fingerprinting
#  - Added High-Concurrency Connection Limits & Fake Traffic
# ============================================================

set -uo pipefail

IFACE="awg0"
CFG_DIR="/etc/amnezia/amneziawg"
CFG="${CFG_DIR}/${IFACE}.conf"
META="${CFG_DIR}/${IFACE}.meta"
IR_ADDR="10.0.0.2"
FR_ADDR="10.0.0.1"
CIDR="30"
KEEP_TCP_PORTS="22,80,443,10052"   # ports that must stay on the Iran server

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
  echo "  AmneziaWG Anti-Filter Tunnel v4.3"
  echo "===================================="
  echo "${RESET}"
}

[[ $EUID -0 ]] || [[ $EUID -eq 0 ]] || die "Run this script as root."

# ---------- helpers ----------
rnd() { # rnd MIN MAX  -> uniform-ish random integer
  local min=$1 max=$2 span=$(( $2 - $1 + 1 ))
  echo $(( min + ( $(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % span ) ))
}

main_iface() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

pub_ip() { curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true; }

# ---------- install ----------
detect_os() {
  . /etc/os-release 2>/dev/null || true
  OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
}

install_tools() {
  detect_os
  info "Installing prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl wget git iptables iproute2 openresolv \
      software-properties-common ca-certificates build-essential \
      "linux-headers-$(uname -r)" >/dev/null 2>&1 || \
  apt-get install -y -qq curl wget git iptables iproute2 \
      software-properties-common ca-certificates build-essential >/dev/null 2>&1

  if [[ "$OS_ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || true
    apt-get update -qq
    apt-get install -y -qq amneziawg amneziawg-tools >/dev/null 2>&1 || true
  fi

  if ! command -v awg >/dev/null 2>&1; then
    warn "Package not available; building amneziawg-tools from source..."
    rm -rf /tmp/awg-tools
    git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-tools /tmp/awg-tools \
      || die "Cannot fetch amneziawg-tools."
    make -s -C /tmp/awg-tools/src -j"$(nproc)" >/dev/null \
      && make -s -C /tmp/awg-tools/src install >/dev/null \
      || die "Build of amneziawg-tools failed."
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
  command -v amneziawg-go >/dev/null 2>&1 && { ok "amneziawg-go already installed."; return 0; }
  warn "Kernel module unavailable (LXC/OpenVZ detected). Installing amneziawg-go..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq golang-go >/dev/null 2>&1 || apt-get install -y -qq golang >/dev/null 2>&1
  command -v go >/dev/null 2>&1 || die "Go toolchain not available."
  rm -rf /tmp/awg-go
  git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-go /tmp/awg-go \
    || die "Cannot fetch amneziawg-go."
  ( cd /tmp/awg-go && go build -o /usr/local/bin/amneziawg-go . ) >/dev/null 2>&1 \
    || die "Build of amneziawg-go failed."
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
}

# ---------- obfuscation profile (with S3 & S4 padding) ----------
gen_profile() {
  JC=$(rnd 3 8)
  JMIN=$(rnd 40 90)
  JMAX=$(rnd $((JMIN + 60)) 1000)
  
  S1=$(rnd 20 140)
  S2=$(rnd 20 140)
  while [[ $((S1 + 56)) -eq $S2 ]]; do S2=$(rnd 20 140); done
  
  S3=$(rnd 10 60)
  S4=$(rnd 10 30)

  H1=$(rnd 100000 2147483000); H2=$(rnd 100000 2147483000)
  H3=$(rnd 100000 2147483000); H4=$(rnd 100000 2147483000)
  while [[ "$H2" == "$H1" ]]; do H2=$(rnd 100000 2147483000); done
  while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3=$(rnd 100000 2147483000); done
  while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4=$(rnd 100000 2147483000); done
}

encode_token() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "v4.3" "$FOREIGN_IP" "$AWG_PORT" "$FR_PUB" "$PSK" \
    "$JC" "$JMIN" "$JMAX" "$S1" "$S2" "$S3" "$S4" "$H1" "$H2" "$H3" "$H4" \
    | base64 -w0
}

decode_token() {
  local raw; raw=$(echo "$1" | tr -d ' \n\r' | base64 -d 2>/dev/null) || die "Invalid token."
  IFS='|' read -r V FOREIGN_IP AWG_PORT FR_PUB PSK JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 <<< "$raw"
  [[ "$V" == "v4.3" || "$V" == "v4.2" || "$V" == "v4" ]] || die "Token version mismatch."
  S3=${S3:-15}
  S4=${S4:-10}
}

# ---------- config writers ----------
common_iface_block() {
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
EOF
}

write_iran_cfg() {
  local NIC=$1
  mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
  { common_iface_block
    cat <<EOF
PostUp = sysctl -qw net.ipv4.ip_forward=1
PostUp = iptables -t nat -N AWG_DNAT 2>/dev/null || true
PostUp = iptables -t nat -F AWG_DNAT
PostUp = iptables -t nat -C PREROUTING -i ${NIC} -j AWG_DNAT 2>/dev/null || iptables -t nat -I PREROUTING 1 -i ${NIC} -j AWG_DNAT
PostUp = iptables -t nat -A AWG_DNAT -p tcp -m multiport ! --dports ${KEEP_TCP_PORTS} -j DNAT --to-destination ${FR_ADDR}
PostUp = iptables -t nat -A AWG_DNAT -p udp -m multiport ! --dports ${AWG_PORT} -j DNAT --to-destination ${FR_ADDR}
PostUp = iptables -t nat -C POSTROUTING -o %i -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = iptables -C FORWARD -i ${NIC} -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${NIC} -o %i -j ACCEPT
PostUp = iptables -C FORWARD -i %i -o ${NIC} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -o ${NIC} -j ACCEPT
PostUp = iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t nat -D PREROUTING -i ${NIC} -j AWG_DNAT 2>/dev/null || true
PostDown = iptables -t nat -F AWG_DNAT 2>/dev/null || true
PostDown = iptables -t nat -X AWG_DNAT 2>/dev/null || true
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
PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -j ACCEPT
PostUp = iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o %i -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${IR_ADDR}/32 -o ${NIC} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${IR_ADDR}/32 -o ${NIC} -j MASQUERADE
PostUp = iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
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

bring_up() {
  set -a; . /etc/default/amneziawg 2>/dev/null || true; set +a
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  ip link del "$IFACE" >/dev/null 2>&1 || true
  awg-quick up "$IFACE" || die "awg-quick failed to start ${IFACE}."
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
  ok "Interface ${IFACE} is up."
}

# --- بهینه‌سازی هسته و محدودسازی کانکشن‌ها برای ترافیک بالا ---
sysctl_tuning() {
  cat > /etc/sysctl.d/99-awg.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.netfilter.nf_conntrack_max = 2000000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2000000
EOF
  sysctl -q --system >/dev/null 2>&1 || true
}

# --- ساخت سرویس تولید ترافیک کاذب (Fake Traffic) روی سرور ایران ---
setup_fake_traffic() {
  info "Configuring Fake Traffic background noise..."
  cat > /usr/local/bin/fake-traffic.sh <<'EOF'
#!/bin/bash
SITES=("https://www.google.com" "https://www.varzesh3.com" "https://www.digikala.com")
while true; do
  # وقفه تصادفی بین ۳۰ تا ۳۰۰ ثانیه
  sleep $(( (RANDOM % 270) + 30 ))
  # ارسال درخواست بسیار کوچک به سایت‌های معتبر جهت شکستن الگوی سکوت یا خطی بودن ترافیک
  curl -fsS -m 5 --max-filesize 1000 ${SITES[$((RANDOM % 3))]} >/dev/null 2>&1
done
EOF
  chmod +x /usr/local/bin/fake-traffic.sh

  cat > /etc/systemd/system/fake-traffic.service <<'EOF'
[Unit]
Description=Fake Traffic Generator
After=network.target

[Service]
ExecStart=/usr/local/bin/fake-traffic.sh
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now fake-traffic.service >/dev/null 2>&1
  ok "Fake traffic service started."
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
  warn "No handshake yet. Check provider firewall for UDP port ${AWG_PORT}."
  return 1
}

# ============================ MENU ============================
banner
cat <<EOF
Select an option:
  1 - IRAN server      (run this AFTER the foreign server)
  2 - FOREIGN server   (run this FIRST)
  3 - FOREIGN: add / update the Iran peer key
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

  DEF_PORT=$(rnd 20000 60000)
  read -rp "AmneziaWG UDP port [random: ${DEF_PORT}]: " AWG_PORT
  AWG_PORT=${AWG_PORT:-$DEF_PORT}
  read -rp "Tunnel MTU [1320]: " MTU; MTU=${MTU:-1320}

  gen_profile
  PRIV=$(awg genkey); FR_PUB=$(echo "$PRIV" | awg pubkey); PSK=$(awg genpsk)
  SELF_ADDR="$FR_ADDR"; IR_PUB=""
  write_foreign_cfg "$NIC"
  {
    echo "ROLE=foreign"; echo "NIC=${NIC}"; echo "PORT=${AWG_PORT}"; echo "MTU=${MTU}"
    echo "PSK=${PSK}"
    echo "TOKEN=$(encode_token)"
  } > "$META"; chmod 600 "$META"
  bring_up

  echo
  ok "Foreign server configured with v2.0 Padding."
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
  read -rp "TCP ports to KEEP on this Iran server [${KEEP_TCP_PORTS}]: " kp
  KEEP_TCP_PORTS=${kp:-$KEEP_TCP_PORTS}

  PRIV=$(awg genkey); IR_PUB=$(echo "$PRIV" | awg pubkey)
  SELF_ADDR="$IR_ADDR"
  write_iran_cfg "$NIC"
  { echo "ROLE=iran"; echo "NIC=${NIC}"; echo "PORT=${AWG_PORT}"; echo "MTU=${MTU}"; } > "$META"
  chmod 600 "$META"
  bring_up
  
  # فعال‌سازی ترافیک کاذب روی سرور ایران
  setup_fake_traffic

  echo
  ok "Iran server configured with Fake Traffic protection."
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
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  awg-quick up "$IFACE" || die "Restart failed."
  ok "Iran peer added successfully."
  ;;

4)
  awg show "$IFACE" 2>/dev/null || echo "No device active."
  ;;

5)
  systemctl disable --now "fake-traffic.service" >/dev/null 2>&1 || true
  rm -f /usr/local/bin/fake-traffic.sh /etc/systemd/system/fake-traffic.service
  systemctl disable --now "awg-quick@${IFACE}" >/dev/null 2>&1 || true
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  rm -rf "$CFG_DIR" /etc/sysctl.d/99-awg.conf /etc/modules-load.d/amneziawg.conf
  ok "Cleaned up completely."
  ;;
*)
  die "Invalid choice."
  ;;
esac
