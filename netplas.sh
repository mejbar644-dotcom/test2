#!/usr/bin/env bash
# ============================================================
# Cloak + Shadowsocks Transparent Gateway
# Iran <-> Foreign
#
# Foreign: Shadowsocks server on localhost + Cloak on public TCP port
# Iran:    ss-redir + Cloak client + iptables REDIRECT rules
#
# Note:
# - Cloak is the active transport layer.
# - ShadowTLS is intentionally NOT run alongside Cloak on the same port.
# - TlsFragment belongs on end-user clients, not these gateways.
# ============================================================

set -euo pipefail

ROLE_DIR="/etc/cloak-gateway"
CFG_DIR="${ROLE_DIR}/config"
META="${ROLE_DIR}/gateway.meta"

CLOAK_SERVER_CFG="${CFG_DIR}/ckserver.json"
CLOAK_CLIENT_CFG="${CFG_DIR}/ckclient.json"
SS_SERVER_CFG="${CFG_DIR}/ss-server.json"
SS_REDIR_CFG="${CFG_DIR}/ss-redir.json"

IFACE_NAME="cloakgw"
LOCAL_SS_PORT="8388"
LOCAL_REDIR_PORT="1080"

# Ports that must remain available directly on the Iran server.
KEEP_TCP_PORTS="22,80,443,10052"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  CYAN=$(tput setaf 6 || true)
  GREEN=$(tput setaf 2 || true)
  YELLOW=$(tput setaf 3 || true)
  RED=$(tput setaf 1 || true)
  BOLD=$(tput bold || true)
  RESET=$(tput sgr0 || true)
else
  CYAN=""; GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

info() { echo "${CYAN}[*]${RESET} $*"; }
ok() { echo "${GREEN}[+]${RESET} $*"; }
warn() { echo "${YELLOW}[!]${RESET} $*"; }
err() { echo "${RED}[x]${RESET} $*" >&2; }
die() { err "$*"; exit 1; }

banner() {
  echo "${CYAN}${BOLD}"
  echo "========================================="
  echo " Cloak + Shadowsocks Transparent Gateway "
  echo "         Iran <-> Foreign v1.0           "
  echo "========================================="
  echo "${RESET}"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."

rnd() {
  local min="$1" max="$2" span=$((max - min + 1))
  echo $((min + ($(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % span)))
}

random_b64() {
  head -c "$1" /dev/urandom | base64 -w0
}

main_iface() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

pub_ip() {
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_ports() {
  [[ "$1" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1

  local port
  IFS=',' read -r -a port_list <<< "$1"

  for port in "${port_list[@]}"; do
    (( port >= 1 && port <= 65535 )) || return 1
  done
}

prepare_dirs() {
  install -d -m 700 "$ROLE_DIR" "$CFG_DIR"
}

install_base() {
  export DEBIAN_FRONTEND=noninteractive

  info "Installing system dependencies..."
  apt-get update -qq

  apt-get install -y -qq \
    ca-certificates curl wget git jq \
    iptables iproute2 \
    shadowsocks-libev \
    golang-go \
    build-essential >/dev/null

  command -v ss-server >/dev/null 2>&1 \
    || die "shadowsocks-libev installation failed."

  command -v ss-redir >/dev/null 2>&1 \
    || die "ss-redir installation failed."
}

install_cloak() {
  if command -v ck-server >/dev/null 2>&1 \
    && command -v ck-client >/dev/null 2>&1; then
    ok "Cloak is already installed."
    return 0
  fi

  info "Building Cloak..."

  rm -rf /tmp/Cloak
  git clone --depth 1 https://github.com/cbeuw/Cloak /tmp/Cloak >/dev/null 2>&1 \
    || die "Unable to clone Cloak repository."

  (
    cd /tmp/Cloak
    go build -o ck-server ./cmd/ck-server
    go build -o ck-client ./cmd/ck-client
  ) >/dev/null 2>&1 || die "Cloak build failed."

  install -m 0755 /tmp/Cloak/ck-server /usr/local/bin/ck-server
  install -m 0755 /tmp/Cloak/ck-client /usr/local/bin/ck-client

  command -v ck-server >/dev/null 2>&1 || die "ck-server is unavailable."
  command -v ck-client >/dev/null 2>&1 || die "ck-client is unavailable."

  ok "Cloak installed."
}

write_sysctl() {
  cat > /etc/sysctl.d/99-cloak-gateway.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_mtu_probing=1
EOF

  sysctl --system >/dev/null 2>&1 || true
}

create_services() {
  cat > /etc/systemd/system/cloak-server.service <<EOF
[Unit]
Description=Cloak Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ck-server -c ${CLOAK_SERVER_CFG}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/cloak-client.service <<EOF
[Unit]
Description=Cloak Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ck-client -c ${CLOAK_CLIENT_CFG} -s \${CLOAK_REMOTE_IP}
EnvironmentFile=-${META}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/ss-server-cloak.service <<EOF
[Unit]
Description=Shadowsocks Server for Cloak
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-server -c ${SS_SERVER_CFG}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/ss-redir-cloak.service <<EOF
[Unit]
Description=Shadowsocks Transparent Redirector for Cloak
After=cloak-client.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-redir -c ${SS_REDIR_CFG}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

encode_token() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "cloak-v1" \
    "$FOREIGN_IP" \
    "$CLOAK_PORT" \
    "$SS_PASSWORD" \
    "$CLOAK_UID" \
    "$CLOAK_PUBLIC_KEY" \
    "$SERVER_NAME" \
    "$LOCAL_SS_PORT" \
    "$ENCRYPTION_METHOD" \
    | base64 -w0
}

decode_token() {
  local raw

  raw=$(echo "$1" | tr -d ' \r\n' | base64 -d 2>/dev/null) \
    || die "Invalid token."

  IFS='|' read -r TOKEN_VERSION FOREIGN_IP CLOAK_PORT SS_PASSWORD \
    CLOAK_UID CLOAK_PUBLIC_KEY SERVER_NAME LOCAL_SS_PORT ENCRYPTION_METHOD \
    <<< "$raw"

  [[ "$TOKEN_VERSION" == "cloak-v1" ]] \
    || die "Unsupported token version."

  [[ -n "$FOREIGN_IP" ]] || die "Token has no foreign IP."
  [[ -n "$CLOAK_PORT" ]] || die "Token has no Cloak port."
  [[ -n "$SS_PASSWORD" ]] || die "Token has no Shadowsocks password."
  [[ -n "$CLOAK_UID" ]] || die "Token has no Cloak UID."
  [[ -n "$CLOAK_PUBLIC_KEY" ]] || die "Token has no Cloak public key."

  valid_port "$CLOAK_PORT" || die "Invalid Cloak port in token."
}

foreign_setup() {
  install_base
  install_cloak
  prepare_dirs
  create_services
  write_sysctl

  FOREIGN_IP=$(pub_ip)

  read -rp "Foreign server public IP [${FOREIGN_IP:-none}]: " input_ip
  FOREIGN_IP="${input_ip:-$FOREIGN_IP}"
  [[ -n "$FOREIGN_IP" ]] || die "Foreign IP is required."

  local default_port
  default_port=$(rnd 20000 60000)

  read -rp "Cloak public TCP port [${default_port}]: " input_port
  CLOAK_PORT="${input_port:-$default_port}"
  valid_port "$CLOAK_PORT" || die "Invalid Cloak port."

  read -rp "Decoy TLS server name [www.cloudflare.com]: " input_name
  SERVER_NAME="${input_name:-www.cloudflare.com}"

  ENCRYPTION_METHOD="chacha20-ietf-poly1305"
  SS_PASSWORD=$(random_b64 32)

  info "Generating Cloak server key and UID..."

  local key_output
  key_output=$(ck-server -key)
  CLOAK_PRIVATE_KEY=$(echo "$key_output" | awk -F': ' '/PrivateKey/{print $2; exit}')
  CLOAK_PUBLIC_KEY=$(echo "$key_output" | awk -F': ' '/PublicKey/{print $2; exit}')

  [[ -n "$CLOAK_PRIVATE_KEY" && -n "$CLOAK_PUBLIC_KEY" ]] \
    || die "Could not generate Cloak key pair."

  CLOAK_UID=$(ck-server -uid | tail -n1 | tr -d '[:space:]')
  [[ -n "$CLOAK_UID" ]] || die "Could not generate Cloak UID."

  cat > "$SS_SERVER_CFG" <<EOF
{
  "server": "127.0.0.1",
  "server_port": ${LOCAL_SS_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${ENCRYPTION_METHOD}",
  "mode": "tcp_only"
}
EOF

  cat > "$CLOAK_SERVER_CFG" <<EOF
{
  "ProxyBook": {
    "shadowsocks": ["tcp", "127.0.0.1:${LOCAL_SS_PORT}"]
  },
  "BindAddr": [":${CLOAK_PORT}"],
  "BypassUID": ["${CLOAK_UID}"],
  "RedirAddr": "${SERVER_NAME}:443",
  "PrivateKey": "${CLOAK_PRIVATE_KEY}",
  "AdminUID": "${CLOAK_UID}",
  "DatabasePath": "${ROLE_DIR}/userinfo.db",
  "StreamTimeout": 300
}
EOF

  cat > "$META" <<EOF
ROLE=foreign
FOREIGN_IP=${FOREIGN_IP}
CLOAK_PORT=${CLOAK_PORT}
SERVER_NAME=${SERVER_NAME}
EOF
  chmod 600 "$META" "$SS_SERVER_CFG" "$CLOAK_SERVER_CFG"

  systemctl enable --now ss-server-cloak.service
  systemctl enable --now cloak-server.service

  ok "Foreign server is configured."
  echo
  echo "${YELLOW}${BOLD}Copy this token to the Iran server:${RESET}"
  echo "${CYAN}$(encode_token)${RESET}"
  echo
  echo "Open TCP port ${CLOAK_PORT} in your provider firewall."
}

iran_rules_up() {
  local nic="$1"
  local keep_ports="$2"

  iptables -t nat -N CLOAK_REDIR 2>/dev/null || true
  iptables -t nat -F CLOAK_REDIR

  iptables -t nat -C PREROUTING -i "$nic" -p tcp -j CLOAK_REDIR 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -i "$nic" -p tcp -j CLOAK_REDIR

  IFS=',' read -r -a ports <<< "$keep_ports"
  local port

  for port in "${ports[@]}"; do
    iptables -t nat -A CLOAK_REDIR -p tcp --dport "$port" -j RETURN
  done

  iptables -t nat -A CLOAK_REDIR -p tcp \
    -m addrtype ! --dst-type LOCAL \
    -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"

  iptables -C FORWARD -i "$nic" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i "$nic" -j ACCEPT
}

iran_rules_down() {
  local nic="$1"

  iptables -t nat -D PREROUTING -i "$nic" -p tcp -j CLOAK_REDIR 2>/dev/null || true
  iptables -t nat -F CLOAK_REDIR 2>/dev/null || true
  iptables -t nat -X CLOAK_REDIR 2>/dev/null || true
  iptables -D FORWARD -i "$nic" -j ACCEPT 2>/dev/null || true
}

iran_setup() {
  install_base
  install_cloak
  prepare_dirs
  create_services
  write_sysctl

  local nic
  nic=$(main_iface)
  [[ -n "$nic" ]] || die "Could not determine default interface."

  echo "Paste the Cloak token from the foreign server:"
  read -rp "> " TOKEN
  decode_token "$TOKEN"

  read -rp "TCP ports to keep on the Iran server [${KEEP_TCP_PORTS}]: " input_ports
  KEEP_TCP_PORTS="${input_ports:-$KEEP_TCP_PORTS}"
  valid_ports "$KEEP_TCP_PORTS" || die "Invalid port list."

  cat > "$CLOAK_CLIENT_CFG" <<EOF
{
  "Transport": "direct",
  "ProxyMethod": "shadowsocks",
  "EncryptionMethod": "plain",
  "UID": "${CLOAK_UID}",
  "PublicKey": "${CLOAK_PUBLIC_KEY}",
  "ServerName": "${SERVER_NAME}",
  "NumConn": 4,
  "BrowserSig": "chrome",
  "StreamTimeout": 300,
  "LocalHost": "127.0.0.1",
  "LocalPort": 1984,
  "RemotePort": "${CLOAK_PORT}"
}
EOF

  cat > "$SS_REDIR_CFG" <<EOF
{
  "server": "127.0.0.1",
  "server_port": 1984,
  "local_address": "0.0.0.0",
  "local_port": ${LOCAL_REDIR_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${ENCRYPTION_METHOD}",
  "mode": "tcp_only"
}
EOF

  cat > "$META" <<EOF
ROLE=iran
CLOAK_REMOTE_IP=${FOREIGN_IP}
CLOAK_PORT=${CLOAK_PORT}
KEEP_TCP_PORTS=${KEEP_TCP_PORTS}
NIC=${nic}
EOF

  chmod 600 "$META" "$CLOAK_CLIENT_CFG" "$SS_REDIR_CFG"

  systemctl enable --now cloak-client.service
  systemctl enable --now ss-redir-cloak.service

  iran_rules_up "$nic" "$KEEP_TCP_PORTS"

  ok "Iran gateway is configured."
  echo
  echo "Transparent TCP redirection is now active."
  echo "Ports kept locally: ${KEEP_TCP_PORTS}"
  echo "Cloak remote endpoint: ${FOREIGN_IP}:${CLOAK_PORT}"
}

diagnostics() {
  echo
  echo "${BOLD}Systemd services:${RESET}"
  systemctl --no-pager --full status \
    cloak-server.service \
    cloak-client.service \
    ss-server-cloak.service \
    ss-redir-cloak.service 2>/dev/null || true

  echo
  echo "${BOLD}Listening ports:${RESET}"
  ss -lntp | grep -E 'ck-|ss-server|ss-redir|:1984|:8388' || true

  echo
  echo "${BOLD}Cloak redirect rules:${RESET}"
  iptables -t nat -S CLOAK_REDIR 2>/dev/null || true
}

cleanup() {
  local nic=""
  [[ -f "$META" ]] && . "$META" || true
  nic="${NIC:-$(main_iface)}"

  systemctl disable --now \
    cloak-server.service \
    cloak-client.service \
    ss-server-cloak.service \
    ss-redir-cloak.service >/dev/null 2>&1 || true

  [[ -n "$nic" ]] && iran_rules_down "$nic"

  rm -f \
    /etc/systemd/system/cloak-server.service \
    /etc/systemd/system/cloak-client.service \
    /etc/systemd/system/ss-server-cloak.service \
    /etc/systemd/system/ss-redir-cloak.service \
    /etc/sysctl.d/99-cloak-gateway.conf

  rm -rf "$ROLE_DIR"

  systemctl daemon-reload
  ok "Cloak gateway configuration removed."
}

banner
cat <<EOF
Choose an option:
  1 - Iran transparent gateway
  2 - Foreign Cloak + Shadowsocks server
  3 - Diagnostics
  4 - Uninstall and clean up
EOF

read -rp "Enter your choice: " CHOICE

case "$CHOICE" in
  1) iran_setup ;;
  2) foreign_setup ;;
  3) diagnostics ;;
  4) cleanup ;;
  *) die "Invalid choice." ;;
esac
