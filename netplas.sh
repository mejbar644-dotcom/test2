#!/usr/bin/env bash
# ============================================================
#  GitHub: Netplas
#  Advanced Anti-DPI Tunnel v2.1 (Hysteria 2 + Salamander)
#  - Optimized for Heavy Load & High Concurrency
#  - Fixed TUN configuration schema for Hysteria v2
# ============================================================

set -uo pipefail

IFACE="hy2-tun"
IR_ADDR="10.0.0.2"
FR_ADDR="10.0.0.1"
KEEP_TCP_PORTS="22,80,443,10052"

# ---------- colors ----------
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
  echo "    Hysteria 2 Ultimate Tunnel"
  echo "===================================="
  echo "${RESET}"
}

[[ $EUID -eq 0 ]] || die "Run this script as root."

main_iface() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

pub_ip() { curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true; }

rnd() { local min=$1 max=$2 span=$(( $2 - $1 + 1 )); echo $(( min + ( $(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % span ) )); }

sysctl_tuning() {
  cat > /etc/sysctl.d/99-netplas-hy2.conf <<'EOF'
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max = 2000000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
EOF
  sysctl -q --system >/dev/null 2>&1 || true
}

install_hy2_binary() {
  if ! command -v hysteria >/dev/null 2>&1; then
    info "Installing Hysteria 2 binary..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1 || die "Failed to install Hysteria 2."
  fi
  ok "Hysteria 2 core is ready."
}

# ============================ MENU ============================
banner
cat <<EOF
Select an option:
  1 - FOREIGN server (Run this FIRST)
  2 - IRAN server    (Run this AFTER foreign)
  3 - Uninstall & Clean
EOF
read -rp "Enter choice: " CHOICE

case "$CHOICE" in
1)
  install_hy2_binary
  sysctl_tuning
  NIC=$(main_iface)
  FOREIGN_IP=$(pub_ip)
  read -rp "Enter Foreign Server IP [${FOREIGN_IP}]: " in_ip
  FOREIGN_IP=${in_ip:-$FOREIGN_IP}

  DEF_PORT=$(rnd 30000 55000)
  read -rp "Hysteria UDP Port [random: ${DEF_PORT}]: " HY_PORT
  HY_PORT=${HY_PORT:-$DEF_PORT}

  AUTH_PASS=$(openssl rand -hex 16)
  OBFS_PASS=$(openssl rand -hex 16)

  mkdir -p /etc/hysteria
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=cloudflare.com" >/dev/null 2>&1

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${AUTH_PASS}

obfuscation:
  type: salamander
  password: ${OBFS_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://cloudflare.com
    rewriteHost: true

ignoreClientBandwidth: false
EOF

  systemctl restart hysteria-server.service >/dev/null 2>&1 || systemctl restart hysteria-server || true

  ok "Foreign Server Configured Successfully!"
  echo
  echo "${YELLOW}${BOLD}Copy these credentials to use on the Iran server:${RESET}"
  echo "${CYAN}Foreign IP : ${FOREIGN_IP}${RESET}"
  echo "${CYAN}Port       : ${HY_PORT}${RESET}"
  echo "${CYAN}Auth Pass  : ${AUTH_PASS}${RESET}"
  echo "${CYAN}Obfs Pass  : ${OBFS_PASS}${RESET}"
  echo
  ;;

2)
  install_hy2_binary
  sysctl_tuning
  NIC=$(main_iface)

  echo "Enter credentials provided by Foreign server:"
  read -rp "Foreign IP: " FOREIGN_IP
  read -rp "Hysteria Port: " HY_PORT
  read -rp "Auth Password: " AUTH_PASS
  read -rp "Obfuscation Password: " OBFS_PASS
  read -rp "TCP ports to keep on Iran [${KEEP_TCP_PORTS}]: " kp
  KEEP_TCP_PORTS=${kp:-$KEEP_TCP_PORTS}

  mkdir -p /etc/hysteria
  cat > /etc/hysteria/client.yaml <<EOF
server: ${FOREIGN_IP}:${HY_PORT}

auth: ${AUTH_PASS}

tls:
  insecure: true

obfuscation:
  type: salamander
  password: ${OBFS_PASS}

tun:
  name: ${IFACE}
  addresses:
    - ${IR_ADDR}/30
  mtu: 1350
EOF

  cat > /etc/systemd/system/netplas-hy2-client.service <<EOF
[Unit]
Description=Netplas Hysteria2 Client Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/client.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now netplas-hy2-client.service

  info "Applying iptables rules for Netplas port forwarding..."
  sysctl -qw net.ipv4.ip_forward=1
  
  iptables -t nat -N NETPLAS_DNAT 2>/dev/null || true
  iptables -t nat -F NETPLAS_DNAT
  iptables -t nat -C PREROUTING -i ${NIC} -j NETPLAS_DNAT 2>/dev/null || iptables -t nat -I PREROUTING 1 -i ${NIC} -j NETPLAS_DNAT
  
  iptables -t nat -A NETPLAS_DNAT -p tcp -m multiport ! --dports ${KEEP_TCP_PORTS} -j DNAT --to-destination ${FR_ADDR}
  iptables -t nat -A NETPLAS_DNAT -p udp -m multiport ! --dports ${HY_PORT} -j DNAT --to-destination ${FR_ADDR}
  
  iptables -t nat -C POSTROUTING -o ${IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE
  iptables -C FORWARD -i ${NIC} -o ${IFACE} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${NIC} -o ${IFACE} -j ACCEPT
  iptables -C FORWARD -i ${IFACE} -o ${NIC} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${IFACE} -o ${NIC} -j ACCEPT
  iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  ok "Iran Server Tunnel Established & Forwarding Active!"
  ;;

3)
  systemctl disable --now netplas-hy2-client.service hysteria-server.service >/dev/null 2>&1 || true
  rm -rf /etc/hysteria /etc/systemd/system/netplas-hy2-client.service
  iptables -t nat -F NETPLAS_DNAT 2>/dev/null || true
  iptables -t nat -X NETPLAS_DNAT 2>/dev/null || true
  ok "Cleaned up completely."
  ;;
*)
  die "Invalid choice."
  ;;
esac
