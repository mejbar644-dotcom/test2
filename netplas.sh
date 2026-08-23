#!/usr/bin/env bash
# ============================================================
# Hysteria 2 Stealth Tunnel (Iran <-> Foreign)
# Optimized for GFW Evasion (QUIC + Salamander Obfs + TUN)
# No Domain Required (SHA256 Pinning)
# Debian / Ubuntu - systemd
# ============================================================

set -uo pipefail
umask 077

IFACE="hy0"
CFG_DIR="/etc/hysteria"
SERVER_CFG="${CFG_DIR}/server.yaml"
CLIENT_CFG="${CFG_DIR}/client.yaml"
BIN="/usr/local/bin/hysteria"

IR_ADDR="10.77.0.2/30"
FR_ADDR="10.77.0.1/30"

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
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1024 && "$1" <= 65535 ))
}

rand_str() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-16}"
}

rand_between() {
  local min=$1 max=$2
  shuf -i "${min}-${max}" -n 1
}

download_binary() {
  if [[ -f "$BIN" ]]; then
    ok "Hysteria 2 already installed."
    return 0
  fi

  info "Downloading latest Hysteria 2 binary..."
  local arch="amd64"
  if [[ "$(uname -m)" == "aarch64" ]]; then arch="arm64"; fi

  curl -fsSL -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}" \
    || die "Failed to download Hysteria 2 binary."

  chmod +x "$BIN"
  ok "Hysteria 2 installed successfully."
}

write_sysctl() {
  cat > /etc/sysctl.d/99-hysteria-tunnel.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
}

generate_cert() {
  mkdir -p "$CFG_DIR"
  chmod 700 "$CFG_DIR"

  if [[ -f "${CFG_DIR}/server.crt" && -f "${CFG_DIR}/server.key" ]]; then
    info "Existing certificate found, reusing..."
  else
    info "Generating self-signed SSL certificate..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "${CFG_DIR}/server.key" -out "${CFG_DIR}/server.crt" \
      -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1 \
      || die "Failed to generate certificate."
  fi

  chmod 600 "${CFG_DIR}/server.key"
  chmod 644 "${CFG_DIR}/server.crt"

  SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${CFG_DIR}/server.crt" \
    | awk -F '=' '{print $2}' | tr -d ':')
}

encode_token() {
  printf '%s|' "h2v1" "$FOREIGN_IP" "$HY_PORT" "$AUTH_PASS" "$OBFUS_PASS" "$SHA256" \
    | base64 -w0
}

decode_token() {
  local raw
  raw=$(printf '%s' "$1" | tr -d '[:space:]' | base64 -d 2>/dev/null) \
    || die "Invalid token."

  IFS='|' read -r VERSION FOREIGN_IP HY_PORT AUTH_PASS OBFUS_PASS SHA256 _ <<< "$raw"

  [[ "$VERSION" == "h2v1" ]] || die "This script accepts only h2v1 tokens."
  valid_ipv4 "$FOREIGN_IP" || die "Invalid foreign IP in token."
  valid_port "$HY_PORT" || die "Invalid port in token."
  [[ -n "$AUTH_PASS" && -n "$OBFUS_PASS" && -n "$SHA256" ]] || die "Incomplete token."
}

foreign_setup() {
  need_cmd curl
  need_cmd openssl
  need_cmd awk
  need_cmd tr
  need_cmd shuf

  download_binary || die "Binary download failed."
  write_sysctl || die "Sysctl write failed."
  generate_cert || die "Certificate generation failed."

  local detected
  detected=$(public_ip)
  read -rp "Foreign public IPv4 [${detected:-required}]: " FOREIGN_IP
  FOREIGN_IP="${FOREIGN_IP:-$detected}"
  valid_ipv4 "$FOREIGN_IP" || die "A valid public IPv4 is required."

  local default_port
  default_port=$(rand_between 20000 60000)
  read -rp "Hysteria 2 UDP port [${default_port}]: " HY_PORT
  HY_PORT="${HY_PORT:-$default_port}"
  valid_port "$HY_PORT" || die "Invalid UDP port."

  AUTH_PASS=$(rand_str 24)
  OBFUS_PASS=$(rand_str 24)

  info "Writing server configuration..."
  cat > "$SERVER_CFG" <<EOF
listen: :${HY_PORT}

tls:
  cert: ${CFG_DIR}/server.crt
  key: ${CFG_DIR}/server.key

obfs:
  type: salamander
  salamander:
    password: "${OBFUS_PASS}"

auth:
  type: password
  password: "${AUTH_PASS}"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF

  info "Creating systemd service..."
  cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=${BIN} server -c ${SERVER_CFG}
Restart=on-failure
RestartSec=5
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

  info "Enabling and starting service..."
  systemctl daemon-reload || die "systemctl daemon-reload failed."
  systemctl enable hysteria-server || die "systemctl enable failed."
  systemctl start hysteria-server || die "systemctl start failed."

  sleep 2
  if systemctl is-active --quiet hysteria-server; then
    ok "Hysteria 2 server is running."
  else
    warn "Hysteria 2 server failed to start. Checking logs..."
    journalctl -u hysteria-server -n 20 --no-pager
    die "Server startup failed."
  fi

  echo
  ok "Foreign side is ready."
  echo "Open UDP/${HY_PORT} in your provider firewall/security group."
  echo
  echo "================================================================"
  echo "Copy this token securely to the Iran server:"
  echo "================================================================"
  encode_token
  echo
  echo
}

iran_setup() {
  need_cmd curl
  need_cmd base64
  need_cmd ip

  download_binary || die "Binary download failed."
  write_sysctl || die "Sysctl write failed."

  modprobe tun 2>/dev/null || true

  echo "======================================================================"
  warn "CRITICAL SECURITY WARNING FOR IRAN SERVER:"
  warn "To prevent IP blocking, you MUST close all incoming ports except SSH."
  warn "Run: ufw default deny incoming && ufw allow <YOUR_SSH_PORT>/tcp && ufw enable"
  echo "======================================================================"
  echo

  echo "Paste the token generated on the foreign server:"
  read -r -p "> " TOKEN
  decode_token "$TOKEN"

  info "Writing client configuration (TUN mode)..."
  cat > "$CLIENT_CFG" <<EOF
server: "${FOREIGN_IP}:${HY_PORT}"
auth: "${AUTH_PASS}"

tls:
  sni: "www.bing.com"
  insecure: false
  pinSHA256: "${SHA256}"

obfs:
  type: salamander
  salamander:
    password: "${OBFUS_PASS}"

transport:
  type: udp
  udp:
    hopInterval: 30s

tun:
  name: "${IFACE}"
  mtu: 1350
  address:
    - "${IR_ADDR}"
  route:
    - "0.0.0.0/0"
  strictRoute: true
EOF

  info "Creating systemd service..."
  cat > /etc/systemd/system/hysteria-client.service <<EOF
[Unit]
Description=Hysteria 2 Client (TUN)
After=network.target

[Service]
Type=simple
ExecStart=${BIN} client -c ${CLIENT_CFG}
Restart=on-failure
RestartSec=5
LimitNOFILE=51200
AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_MODULE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_SYS_MODULE

[Install]
WantedBy=multi-user.target
EOF

  info "Enabling and starting service..."
  systemctl daemon-reload || die "systemctl daemon-reload failed."
  systemctl enable hysteria-client || die "systemctl enable failed."
  systemctl start hysteria-client || die "systemctl start failed."

  sleep 4
  if ip link show "$IFACE" >/dev/null 2>&1; then
    ok "Hysteria 2 tunnel established (${IFACE} is up)."
  else
    warn "Interface ${IFACE} not found. Checking logs..."
    journalctl -u hysteria-client -n 20 --no-pager
    die "Tunnel interface did not come up."
  fi
}

diagnostics() {
  echo "=== Hysteria Service Status ==="
  systemctl status hysteria-client --no-pager -n 15 2>/dev/null \
    || systemctl status hysteria-server --no-pager -n 15 2>/dev/null \
    || echo "No hysteria service found."
  echo
  echo "=== Interface ==="
  ip -4 addr show "$IFACE" 2>/dev/null || echo "Interface ${IFACE} not found."
  echo
  echo "=== Routes ==="
  ip route show dev "$IFACE" 2>/dev/null || echo "No routes for ${IFACE}."
  echo
  echo "=== Recent Logs ==="
  journalctl -u hysteria-client -n 30 --no-pager 2>/dev/null \
    || journalctl -u hysteria-server -n 30 --no-pager 2>/dev/null \
    || echo "No logs available."
}

uninstall_all() {
  info "Removing Hysteria 2 completely..."
  systemctl disable --now hysteria-client hysteria-server 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria-client.service
  rm -f /etc/systemd/system/hysteria-server.service
  systemctl daemon-reload

  rm -rf "$CFG_DIR"
  rm -f "$BIN"
  rm -f /etc/sysctl.d/99-hysteria-tunnel.conf
  sysctl --system >/dev/null 2>&1 || true
  ip link delete "$IFACE" 2>/dev/null || true
  ok "Hysteria 2 removed completely."
}

echo
echo "=========================================================="
echo " Hysteria 2 Stealth Tunnel (Anti-GFW Optimized)"
echo "=========================================================="
echo "1) Configure Iran server      (run AFTER foreign)"
echo "2) Configure foreign server   (run FIRST)"
echo "3) Diagnostics"
echo "4) Uninstall tunnel"
echo

read -r -p "Choice: " CHOICE

case "$CHOICE" in
  1) iran_setup ;;
  2) foreign_setup ;;
  3) diagnostics ;;
  4) uninstall_all ;;
  *) die "Invalid choice." ;;
esac
