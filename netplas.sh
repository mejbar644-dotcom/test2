#!/usr/bin/env bash
# ============================================================
# Hysteria 2 Stealth Tunnel (Iran <-> Foreign)
# Version: 2.4.0
# - Auto cleanup before setup
# - Version detection for correct config format
# - Optimized for GFW Evasion
# ============================================================

set -uo pipefail
umask 077

SCRIPT_VERSION="2.4.0"
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

cleanup_previous() {
  info "Cleaning up previous installation..."
  systemctl stop hysteria-client 2>/dev/null || true
  systemctl stop hysteria-server 2>/dev/null || true
  systemctl disable hysteria-client 2>/dev/null || true
  systemctl disable hysteria-server 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria-client.service
  rm -f /etc/systemd/system/hysteria-server.service
  systemctl daemon-reload
  ip link delete "$IFACE" 2>/dev/null || true
  ok "Cleanup complete."
}

download_binary() {
  # Remove old binary to get fresh version
  rm -f "$BIN"
  
  info "Downloading latest Hysteria 2 binary..."
  local arch="amd64"
  if [[ "$(uname -m)" == "aarch64" ]]; then arch="arm64"; fi

  curl -fsSL -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}" \
    || die "Failed to download Hysteria 2 binary."

  chmod +x "$BIN"
  
  # Show version
  local ver
  ver=$("$BIN" version 2>&1 | head -1 || echo "unknown")
  ok "Hysteria 2 installed: $ver"
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

  # Remove old certs
  rm -f "${CFG_DIR}/server.crt" "${CFG_DIR}/server.key"

  info "Generating self-signed SSL certificate..."
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "${CFG_DIR}/server.key" -out "${CFG_DIR}/server.crt" \
    -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1 \
    || die "Failed to generate certificate."

  chmod 600 "${CFG_DIR}/server.key"
  chmod 644 "${CFG_DIR}/server.crt"

  SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${CFG_DIR}/server.crt" \
    | awk -F '=' '{print $2}' | tr -d ':')
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
  cleanup_previous
  download_binary
  write_sysctl
  generate_cert

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

  systemctl daemon-reload
  systemctl enable --now hysteria-server

  sleep 2
  if systemctl is-active --quiet hysteria-server; then
    ok "Hysteria 2 server is running."
  else
    journalctl -u hysteria-server -n 20 --no-pager
    die "Server startup failed."
  fi

  echo
  ok "Foreign side is ready."
  echo
  echo "================================================================"
  echo "CRITICAL: Open UDP/${HY_PORT} in your provider firewall!"
  echo "================================================================"
  echo
  echo "Copy this token to the Iran server:"
  echo "================================================================"
  encode_token
  echo
}

iran_setup() {
  cleanup_previous
  download_binary
  write_sysctl

  mkdir -p "$CFG_DIR"
  chmod 700 "$CFG_DIR"

  modprobe tun 2>/dev/null || true

  echo "======================================================================"
  warn "CRITICAL SECURITY WARNING FOR IRAN SERVER:"
  warn "Close all incoming ports except SSH to prevent IP blocking."
  warn "Run: ufw default deny incoming && ufw allow <SSH_PORT>/tcp && ufw enable"
  echo "======================================================================"
  echo

  echo "Paste the token from foreign server:"
  read -r -p "> " TOKEN
  decode_token "$TOKEN"

  info "Testing UDP connectivity..."
  if timeout 5 bash -c "echo -n '' > /dev/udp/${FOREIGN_IP}/${HY_PORT}" 2>/dev/null; then
    ok "UDP port ${HY_PORT} appears reachable."
  else
    warn "Cannot verify UDP connectivity. Make sure UDP/${HY_PORT} is open!"
    read -rp "Continue anyway? (y/N): " CONTINUE
    [[ "$CONTINUE" =~ ^[Yy]$ ]] || die "Aborted."
  fi

  info "Writing client configuration..."
  # Using the simplest TUN config format that works across versions
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

tun:
  name: ${IFACE}
  mtu: 1350
  address: ${IR_ADDR}
  strictRoute: false
EOF

  info "Testing config file validity..."
  if ! "$BIN" client -c "$CLIENT_CFG" --test 2>&1 | grep -qi "error"; then
    ok "Config file is valid."
  else
    warn "Config validation showed warnings, but continuing..."
    "$BIN" client -c "$CLIENT_CFG" --test 2>&1 || true
  fi

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

  info "Starting service..."
  systemctl daemon-reload
  systemctl enable --now hysteria-client

  sleep 5
  
  if ip link show "$IFACE" >/dev/null 2>&1; then
    ok "Hysteria 2 tunnel established (${IFACE} is up)."
    echo
    echo "=== Connection Info ==="
    ip -4 addr show "$IFACE"
    echo
  else
    warn "Interface ${IFACE} not found. Checking logs..."
    journalctl -u hysteria-client -n 30 --no-pager
    echo
    echo "=== Current Config File ==="
    cat "$CLIENT_CFG"
    die "Tunnel interface did not come up."
  fi
}

diagnostics() {
  echo "=== Script Version: ${SCRIPT_VERSION} ==="
  echo
  echo "=== Hysteria Binary ==="
  "$BIN" version 2>&1 || echo "Not installed"
  echo
  echo "=== Service Status ==="
  systemctl status hysteria-client --no-pager -n 15 2>/dev/null \
    || systemctl status hysteria-server --no-pager -n 15 2>/dev/null \
    || echo "No service found."
  echo
  echo "=== Interface ==="
  ip -4 addr show "$IFACE" 2>/dev/null || echo "Interface ${IFACE} not found."
  echo
  echo "=== Config File ==="
  if [[ -f "$CLIENT_CFG" ]]; then
    cat "$CLIENT_CFG"
  elif [[ -f "$SERVER_CFG" ]]; then
    cat "$SERVER_CFG"
  else
    echo "No config found."
  fi
}

uninstall_all() {
  cleanup_previous
  rm -rf "$CFG_DIR"
  rm -f "$BIN"
  rm -f /etc/sysctl.d/99-hysteria-tunnel.conf
  sysctl --system >/dev/null 2>&1 || true
  ok "Hysteria 2 completely removed."
}

echo
echo "=========================================================="
echo " Hysteria 2 Stealth Tunnel v${SCRIPT_VERSION}"
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
