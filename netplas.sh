#!/usr/bin/env bash
#
# Netplas Gost TCP Tunnel Installer
#

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
info() { echo -e "${WHITE}[*]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then err "Please run as root (sudo)."; exit 1; fi

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "    Gost Anti-Filter TCP Tunnel"
echo "===================================="
echo -e "${NC}"

# نصب پیش‌نیازها و دانلود Gost
if ! command -v gost &> /dev/null; then
    info "Installing Gost and dependencies..."
    apt-get update
    apt-get install -y curl wget ufw
    
    # دانلود آخرین نسخه Gost از گیت‌هاب
    GOST_VER="3.0.0-rc.9" # یا آخرین نسخه پایدار
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        GOST_ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        GOST_ARCH="arm64"
    else
        err "Unsupported architecture: $ARCH"
        exit 1
    fi
    
    GOST_URL="https://github.com/go-gost/gost/releases/download/v2.11.5/gost_2.11.5_linux_${GOST_ARCH}.tar.gz"
    curl -sL "$GOST_URL" -o /tmp/gost.tar.gz
    tar -xzf /tmp/gost.tar.gz -C /usr/local/bin/ gost
    chmod +x /usr/local/bin/gost
    rm -f /tmp/gost.tar.gz
fi

echo "Select an option:"
echo "1 - IRAN Server Configuration (Relay)"
echo "2 - FOREIGN Server Configuration (Receiver)"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

if [[ "$LOCATION" == "3" ]]; then
    warn "Uninstalling and cleaning up Gost tunnel..."
    systemctl stop gost 2>/dev/null
    systemctl disable gost 2>/dev/null
    rm -f /etc/systemd/system/gost.service
    rm -f /usr/local/bin/gost
    iptables -t nat -F PREROUTING
    success "Gost tunnel and all configurations removed successfully!"
    exit 0
fi

read -p "Enter Tunnel Port (Default 443 or 8443): " TUNNEL_PORT
TUNNEL_PORT=${TUNNEL_PORT:-8443}

if [[ "$LOCATION" == "1" ]]; then
    info "Configuring IRAN server with Gost (TCP Forwarder)..."
    read -p "Enter FOREIGN server IP: " IP_FOREIGN

    # ایجاد سرویس Systemd برای پایدار ماندن تونل در سرور ایران
    cat << EOF > /etc/systemd/system/gost.service
[Unit]
Description=Gost Tunnel Iran Service
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -L tcp://:$TUNNEL_PORT/$IP_FOREIGN:$TUNNEL_PORT -F relay+tcp://$IP_FOREIGN:$TUNNEL_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost

    success "Iran server configured successfully! Traffic is tunneling via TCP safely."

elif [[ "$LOCATION" == "2" ]]; then
    info "Configuring FOREIGN server with Gost (TCP Listener)..."

    # ایجاد سرویس Systemd برای سرور خارج
    cat << EOF > /etc/systemd/system/gost.service
[Unit]
Description=Gost Tunnel Foreign Service
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -L tcp://:$TUNNEL_PORT/$IP_FOREIGN:$TUNNEL_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost

    success "Foreign server configured successfully and listening on port $TUNNEL_PORT!"

else
    err "Invalid selection. Please enter 1, 2 or 3."
    exit 1
fi
