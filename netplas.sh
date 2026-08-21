#!/usr/bin/env bash
# ============================================================
# Cloak / ShadowTLS + Shadowsocks Gateway
# Iran <-> Foreign
#
# Modes:
#   1. cloak      : Shadowsocks over Cloak
#   2. shadowtls  : Shadowsocks over ShadowTLS v3
#
# Client-side optional:
#   3. TlsFragment source installer
#
# Important:
# - Only ONE transport mode is active at a time.
# - TlsFragment is a client-side component, not a gateway daemon.
# - Rotation of password/port requires a fresh token on both sides.
# ============================================================

set -euo pipefail

BASE_DIR="/etc/stealth-gateway"
CFG_DIR="${BASE_DIR}/config"
META="${BASE_DIR}/gateway.meta"
STATE_DIR="${BASE_DIR}/state"

SS_SERVER_CFG="${CFG_DIR}/ss-server.json"
SS_REDIR_CFG="${CFG_DIR}/ss-redir.json"

CLOAK_SERVER_CFG="${CFG_DIR}/ckserver.json"
CLOAK_CLIENT_CFG="${CFG_DIR}/ckclient.json"

LOCAL_SS_PORT="8388"
LOCAL_REDIR_PORT="1080"
LOCAL_CLOAK_PORT="1984"
LOCAL_SHADOWTLS_PORT="1985"

KEEP_TCP_PORTS="22,80,443,10052"
DEFAULT_METHOD="chacha20-ietf-poly1305"

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
  echo "================================================"
  echo " Cloak / ShadowTLS + Shadowsocks Gateway v2.0 "
  echo "                Iran <-> Foreign                "
  echo "================================================"
  echo "${RESET}"
}

[[ "${EUID}" -eq 0 ]] || die "Run this script as root."

rnd() {
  local min="$1" max="$2" span=$((max - min + 1))
  echo $((min + ($(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % span)))
}

random_b64() {
  head -c "$1" /dev/urandom | base64 -w0
}

main_iface() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

public_ip() {
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_port_list() {
  [[ "$1" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1

  local port
  IFS=',' read -r -a ports <<< "$1"

  for port in "${ports[@]}"; do
    ((port >= 1 && port <= 65535)) || return 1
  done
}

prepare_dirs() {
  install -d -m 700 "$BASE_DIR" "$CFG_DIR" "$STATE_DIR"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive

  info "Installing dependencies..."

  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    iproute2 \
    iptables \
    shadowsocks-libev \
    build-essential \
    golang-go \
    cargo \
    rustc \
    pkg-config \
    libssl-dev \
    libffi-dev \
    python3 \
    python3-pip \
    zlib1g-dev >/dev/null

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
    || die "Cannot clone Cloak source."

  (
    cd /tmp/Cloak
    go build -o ck-server ./cmd/ck-server
    go build -o ck-client ./cmd/ck-client
  ) >/dev/null 2>&1 || die "Cloak build failed."

  install -m 0755 /tmp/Cloak/ck-server /usr/local/bin/ck-server
  install -m 0755 /tmp/Cloak/ck-client /usr/local/bin/ck-client

  command -v ck-server >/dev/null 2>&1 \
    || die "ck-server installation failed."

  command -v ck-client >/dev/null 2>&1 \
    || die "ck-client installation failed."

  ok "Cloak installed."
}

install_shadowtls() {
  if command -v shadow-tls >/dev/null 2>&1; then
    ok "ShadowTLS is already installed."
    return 0
  fi

  info "Installing ShadowTLS..."

  cargo install shadow-tls --root /usr/local >/dev/null 2>&1 \
    || die "ShadowTLS installation failed."

  ln -sf /usr/local/bin/shadow-tls /usr/bin/shadow-tls

  command -v shadow-tls >/dev/null 2>&1 \
    || die "shadow-tls binary not found."

  ok "ShadowTLS installed."
}

write_sysctl() {
  cat > /etc/sysctl.d/99-stealth-gateway.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
EOF

  sysctl --system >/dev/null 2>&1 || true
}

disable_transports() {
  systemctl disable --now \
    cloak-server.service \
    cloak-client.service \
    shadowtls-server.service \
    shadowtls-client.service \
    >/dev/null 2>&1 || true
}

write_ss_server() {
  cat > "$SS_SERVER_CFG" <<EOF
{
  "server": "127.0.0.1",
  "server_port": ${LOCAL_SS_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${SS_METHOD}",
  "mode": "tcp_only"
}
EOF

  chmod 600 "$SS_SERVER_CFG"

  cat > /etc/systemd/system/stealth-ss-server.service <<EOF
[Unit]
Description=Shadowsocks Server for Stealth Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-server -c ${SS_SERVER_CFG}
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
}

write_ss_redir() {
  local upstream_port="$1"

  cat > "$SS_REDIR_CFG" <<EOF
{
  "server": "127.0.0.1",
  "server_port": ${upstream_port},
  "local_address": "0.0.0.0",
  "local_port": ${LOCAL_REDIR_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${SS_METHOD}",
  "mode": "tcp_only"
}
EOF

  chmod 600 "$SS_REDIR_CFG"

  cat > /etc/systemd/system/stealth-ss-redir.service <<EOF
[Unit]
Description=Shadowsocks Transparent Redirector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-redir -c ${SS_REDIR_CFG}
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
}

write_cloak_foreign() {
  local key_output

  key_output=$(ck-server -key)
  CLOAK_PRIVATE_KEY=$(echo "$key_output" | awk -F': ' '/PrivateKey/{print $2; exit}')
  CLOAK_PUBLIC_KEY=$(echo "$key_output" | awk -F': ' '/PublicKey/{print $2; exit}')
  CLOAK_UID=$(ck-server -uid | tail -n1 | tr -d '[:space:]')

  [[ -n "$CLOAK_PRIVATE_KEY" ]] || die "Cannot create Cloak private key."
  [[ -n "$CLOAK_PUBLIC_KEY" ]] || die "Cannot create Cloak public key."
  [[ -n "$CLOAK_UID" ]] || die "Cannot create Cloak UID."

  cat > "$CLOAK_SERVER_CFG" <<EOF
{
  "ProxyBook": {
    "shadowsocks": ["tcp", "127.0.0.1:${LOCAL_SS_PORT}"]
  },
  "BindAddr": [":${TRANSPORT_PORT}"],
  "BypassUID": ["${CLOAK_UID}"],
  "RedirAddr": "${DECOY_HOST}:443",
  "PrivateKey": "${CLOAK_PRIVATE_KEY}",
  "AdminUID": "${CLOAK_UID}",
  "DatabasePath": "${STATE_DIR}/cloak-users.db",
  "StreamTimeout": 300
}
EOF

  chmod 600 "$CLOAK_SERVER_CFG"

  cat > /etc/systemd/system/cloak-server.service <<EOF
[Unit]
Description=Cloak Server
After=network-online.target stealth-ss-server.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ck-server -c ${CLOAK_SERVER_CFG}
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
}

write_cloak_iran() {
  cat > "$CLOAK_CLIENT_CFG" <<EOF
{
  "Transport": "direct",
  "ProxyMethod": "shadowsocks",
  "EncryptionMethod": "plain",
  "UID": "${CLOAK_UID}",
  "PublicKey": "${CLOAK_PUBLIC_KEY}",
  "ServerName": "${DECOY_HOST}",
  "NumConn": 4,
  "BrowserSig": "chrome",
  "StreamTimeout": 300,
  "LocalHost": "127.0.0.1",
  "LocalPort": ${LOCAL_CLOAK_PORT},
  "RemotePort": ${TRANSPORT_PORT}
}
EOF

  chmod 600 "$CLOAK_CLIENT_CFG"

  cat > /etc/systemd/system/cloak-client.service <<EOF
[Unit]
Description=Cloak Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${META}
ExecStart=/usr/local/bin/ck-client -c ${CLOAK_CLIENT_CFG} -s \${FOREIGN_IP}
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
}

write_shadowtls_foreign() {
  cat > /etc/systemd/system/shadowtls-server.service <<EOF
[Unit]
Description=ShadowTLS v3 Server
After=network-online.target stealth-ss-server.service
Wants=network-online.target

[Service]
Type=simple
Environment=RUST_LOG=error
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=/usr/bin/shadow-tls --v3 server \\
  --listen 0.0.0.0:${TRANSPORT_PORT} \\
  --server 127.0.0.1:${LOCAL_SS_PORT} \\
  --tls "${SNI_LIST}" \\
  --password "${SHADOWTLS_PASSWORD}"
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
}

choose_sni() {
  local entries=()
  IFS=';' read -r -a entries <<< "$SNI_LIST"
  (( ${#entries[@]} > 0 )) || die "SNI list is empty."
  echo "${entries[$((RANDOM % ${#entries[@]}))]}"
}

write_shadowtls_iran() {
  ACTIVE_SNI=$(choose_sni)

  printf '%s\n' "$ACTIVE_SNI" > "${STATE_DIR}/active-sni"
  chmod 600 "${STATE_DIR}/active-sni"

  cat > /etc/systemd/system/shadowtls-client.service <<EOF
[Unit]
Description=ShadowTLS v3 Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${META}
Environment=RUST_LOG=error
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=/usr/bin/shadow-tls --v3 client \\
  --listen 127.0.0.1:${LOCAL_SHADOWTLS_PORT} \\
  --server \${FOREIGN_IP}:${TRANSPORT_PORT} \\
  --sni "${ACTIVE_SNI}" \\
  --password "${SHADOWTLS_PASSWORD}"
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
}

write_rotation_tools() {
  cat > /usr/local/sbin/stealth-rotate-sni <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

META="/etc/stealth-gateway/gateway.meta"
STATE="/etc/stealth-gateway/state/active-sni"

[[ -f "$META" ]] || exit 0
. "$META"

[[ "${MODE:-}" == "shadowtls" ]] || exit 0
[[ -n "${SNI_LIST:-}" ]] || exit 0

IFS=';' read -r -a SNIS <<< "$SNI_LIST"
(( ${#SNIS[@]} > 0 )) || exit 0

NEW_SNI="${SNIS[$((RANDOM % ${#SNIS[@]}))]}"
printf '%s\n' "$NEW_SNI" > "$STATE"
chmod 600 "$STATE"

sed -i \
  -E "s/(--sni \")[^\"]+/\1${NEW_SNI}/" \
  /etc/systemd/system/shadowtls-client.service

systemctl daemon-reload
systemctl restart shadowtls-client.service
EOF

  chmod 700 /usr/local/sbin/stealth-rotate-sni

  cat > /etc/systemd/system/stealth-rotate-sni.service <<'EOF'
[Unit]
Description=Rotate ShadowTLS SNI

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/stealth-rotate-sni
EOF

  cat > /etc/systemd/system/stealth-rotate-sni.timer <<'EOF'
[Unit]
Description=Periodic ShadowTLS SNI rotation

[Timer]
OnBootSec=20min
OnUnitActiveSec=24h
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now stealth-rotate-sni.timer >/dev/null 2>&1 || true
}

enable_transparent_redirect() {
  local nic="$1"
  local port_list="$2"

  iptables -t nat -N STEALTH_REDIR 2>/dev/null || true
  iptables -t nat -F STEALTH_REDIR

  iptables -t nat -C PREROUTING -i "$nic" -p tcp -j STEALTH_REDIR 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -i "$nic" -p tcp -j STEALTH_REDIR

  IFS=',' read -r -a ports <<< "$port_list"

  local port
  for port in "${ports[@]}"; do
    iptables -t nat -A STEALTH_REDIR -p tcp --dport "$port" -j RETURN
  done

  iptables -t nat -A STEALTH_REDIR \
    -p tcp \
    -m addrtype ! --dst-type LOCAL \
    -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"
}

disable_transparent_redirect() {
  local nic="${1:-}"

  [[ -n "$nic" ]] && \
    iptables -t nat -D PREROUTING -i "$nic" -p tcp -j STEALTH_REDIR 2>/dev/null || true

  iptables -t nat -F STEALTH_REDIR 2>/dev/null || true
  iptables -t nat -X STEALTH_REDIR 2>/dev/null || true
}

encode_token() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "stealth-v2" \
    "$MODE" \
    "$FOREIGN_IP" \
    "$TRANSPORT_PORT" \
    "$SS_PASSWORD" \
    "$SS_METHOD" \
    "$DECOY_HOST" \
    "$CLOAK_UID" \
    "$CLOAK_PUBLIC_KEY" \
    "$SHADOWTLS_PASSWORD" \
    "$SNI_LIST" \
    | base64 -w0
}

decode_token() {
  local raw

  raw=$(echo "$1" | tr -d ' \r\n' | base64 -d 2>/dev/null) \
    || die "Invalid token."

  IFS='|' read -r \
    TOKEN_VERSION \
    MODE \
    FOREIGN_IP \
    TRANSPORT_PORT \
    SS_PASSWORD \
    SS_METHOD \
    DECOY_HOST \
    CLOAK_UID \
    CLOAK_PUBLIC_KEY \
    SHADOWTLS_PASSWORD \
    SNI_LIST <<< "$raw"

  [[ "$TOKEN_VERSION" == "stealth-v2" ]] \
    || die "Token version mismatch."

  [[ "$MODE" == "cloak" || "$MODE" == "shadowtls" ]] \
    || die "Invalid transport mode."

  valid_port "$TRANSPORT_PORT" \
    || die "Invalid transport port."

  [[ -n "$SS_PASSWORD" && -n "$FOREIGN_IP" ]] \
    || die "Token is incomplete."
}

setup_foreign() {
  install_dependencies
  prepare_dirs
  write_sysctl
  disable_transports

  FOREIGN_IP=$(public_ip)

  read -rp "Foreign public IP [${FOREIGN_IP:-none}]: " input_ip
  FOREIGN_IP="${input_ip:-$FOREIGN_IP}"
  [[ -n "$FOREIGN_IP" ]] || die "Foreign IP is required."

  echo "Select transport:"
  echo "  1 - Cloak"
  echo "  2 - ShadowTLS v3"
  read -rp "Choice: " transport_choice

  case "$transport_choice" in
    1) MODE="cloak" ;;
    2) MODE="shadowtls" ;;
    *) die "Invalid transport choice." ;;
  esac

  local default_port
  default_port=$(rnd 20000 60000)

  read -rp "Public transport TCP port [${default_port}]: " input_port
  TRANSPORT_PORT="${input_port:-$default_port}"
  valid_port "$TRANSPORT_PORT" || die "Invalid port."

  read -rp "Decoy host for Cloak [www.cloudflare.com]: " input_decoy
  DECOY_HOST="${input_decoy:-www.cloudflare.com}"

  SS_METHOD="$DEFAULT_METHOD"
  SS_PASSWORD=$(random_b64 32)

  CLOAK_UID=""
  CLOAK_PUBLIC_KEY=""
  SHADOWTLS_PASSWORD=""
  SNI_LIST=""

  write_ss_server

  if [[ "$MODE" == "cloak" ]]; then
    install_cloak
    write_cloak_foreign
  else
    install_shadowtls

    read -rp "SNI list, separated by ; [www.cloudflare.com;www.microsoft.com]: " input_sni
    SNI_LIST="${input_sni:-www.cloudflare.com;www.microsoft.com}"

    SHADOWTLS_PASSWORD=$(random_b64 32)
    write_shadowtls_foreign
  fi

  cat > "$META" <<EOF
ROLE=foreign
MODE=${MODE}
FOREIGN_IP=${FOREIGN_IP}
TRANSPORT_PORT=${TRANSPORT_PORT}
DECOY_HOST=${DECOY_HOST}
SNI_LIST=${SNI_LIST}
EOF
  chmod 600 "$META"

  systemctl daemon-reload
  systemctl enable --now stealth-ss-server.service

  if [[ "$MODE" == "cloak" ]]; then
    systemctl enable --now cloak-server.service
  else
    systemctl enable --now shadowtls-server.service
  fi

  ok "Foreign ${MODE} server is ready."
  echo
  echo "${YELLOW}${BOLD}Copy this token to the Iran server:${RESET}"
  echo "${CYAN}$(encode_token)${RESET}"
  echo
  echo "Allow TCP port ${TRANSPORT_PORT} in your VPS firewall."
}

setup_iran() {
  install_dependencies
  prepare_dirs
  write_sysctl
  disable_transports

  local nic
  nic=$(main_iface)
  [[ -n "$nic" ]] || die "Cannot determine default network interface."

  echo "Paste the token produced on the foreign server:"
  read -rp "> " token
  decode_token "$token"

  read -rp "TCP ports to keep locally [${KEEP_TCP_PORTS}]: " local_ports
  KEEP_TCP_PORTS="${local_ports:-$KEEP_TCP_PORTS}"
  valid_port_list "$KEEP_TCP_PORTS" || die "Invalid TCP port list."

  if [[ "$MODE" == "cloak" ]]; then
    install_cloak
    write_cloak_iran
    write_ss_redir "$LOCAL_CLOAK_PORT"
  else
    install_shadowtls
    write_shadowtls_iran
    write_ss_redir "$LOCAL_SHADOWTLS_PORT"
    write_rotation_tools
  fi

  cat > "$META" <<EOF
ROLE=iran
MODE=${MODE}
FOREIGN_IP=${FOREIGN_IP}
TRANSPORT_PORT=${TRANSPORT_PORT}
