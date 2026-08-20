#!/bin/bash

# AmneziaWG Anti-Filter Tunnel v4 (Improved)
# GitHub style: Netplas / Improved by Grok

set -euo pipefail

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "========================================"
echo "     AmneziaWG Anti-Filter Tunnel v4"
echo "========================================"
echo -e "${RESET}"

# ---------- توابع کمکی ----------
generate_random_params() {
    JC=$((3 + RANDOM % 5))          # 3-7
    JMIN=$((40 + RANDOM % 40))      # 40-79
    JMAX=$((JMIN + 200 + RANDOM % 800))  # بزرگ‌تر از JMIN
    S1=$((40 + RANDOM % 60))
    S2=$((40 + RANDOM % 60))
    H1=$((RANDOM * RANDOM))
    H2=$((RANDOM * RANDOM))
    H3=$((RANDOM * RANDOM))
    H4=$((RANDOM * RANDOM))
}

save_iptables() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    fi
}

# ---------- نصب پیش‌نیاز ----------
if ! command -v awg &>/dev/null; then
    echo -e "${YELLOW}[*] Installing AmneziaWG and dependencies...${RESET}"
    apt-get update -qq
    apt-get install -y curl wget iptables iptables-persistent software-properties-common
    add-apt-repository -y ppa:amnezia/ppa &>/dev/null || true
    apt-get update -qq
    apt-get install -y amneziawg amneziawg-tools
fi

# ---------- منوی اصلی ----------
echo "Select an option:"
echo "1 - IRAN Server Configuration"
echo "2 - FOREIGN Server Configuration"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up...${RESET}"
    systemctl stop awg-quick@awg0 2>/dev/null || true
    systemctl disable awg-quick@awg0 2>/dev/null || true
    ip link set awg0 down 2>/dev/null || true
    ip link del awg0 2>/dev/null || true
    rm -rf /etc/amnezia
    rm -f /etc/systemd/system/awg-quick@awg0.service
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    systemctl daemon-reload
    echo -e "${GREEN}[+] Tunnel and all configurations removed successfully!${RESET}"
    exit 0
fi

read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN
read -p "Enter AmneziaWG Port (Default 51820): " AWG_PORT
AWG_PORT=${AWG_PORT:-51820}

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
[[ -z "$MAIN_INTERFACE" ]] && { echo -e "${RED}[!] Could not detect main interface${RESET}"; exit 1; }

# حذف اینترفیس قبلی
ip link del awg0 2>/dev/null || true
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia /etc/amnezia/amneziawg

generate_random_params

if [[ "$LOCATION" == "1" ]]; then
    # ==================== سرور ایران ====================
    echo -e "${YELLOW}[*] Configuring IRAN server...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key

    echo -e "${YELLOW}[?] First run the FOREIGN server script and copy its Public Key.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    # ساخت فایل کانفیگ دائمی
    cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
PrivateKey = $PrivKey
Address = 10.0.0.2/30
ListenPort = $AWG_PORT
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $FOREIGN_PUBKEY
Endpoint = $IP_FOREIGN:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 35
EOF

    chmod 600 /etc/amnezia/amneziawg/awg0.conf

    # فعال‌سازی forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-amnezia.conf

    # بالا آوردن اینترفیس
    awg-quick down awg0 2>/dev/null || true
    awg-quick up awg0

    # قوانین iptables
    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT

    save_iptables

    # فعال‌سازی سرویس
    systemctl enable awg-quick@awg0
    systemctl daemon-reload

    echo -e "${GREEN}[+] Iran server configured successfully!${RESET}"
    echo -e "Iran Public Key: ${CYAN}$PubKey${RESET}"
    echo -e "Obfuscation params used → Jc=$JC  Jmin=$JMIN  Jmax=$JMAX"

elif [[ "$LOCATION" == "2" ]]; then
    # ==================== سرور خارج ====================
    echo -e "${YELLOW}[*] Configuring FOREIGN server...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${RESET}"
    read -p "Press Enter after you have saved this key..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
PrivateKey = $PrivKey
Address = 10.0.0.1/30
ListenPort = $AWG_PORT
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $IRAN_PUBKEY
Endpoint = $IP_IRAN:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 35
EOF

    chmod 600 /etc/amnezia/amneziawg/awg0.conf

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-amnezia.conf

    awg-quick down awg0 2>/dev/null || true
    awg-quick up awg0

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    save_iptables

    systemctl enable awg-quick@awg0
    systemctl daemon-reload

    echo -e "${GREEN}[+] Foreign server configured successfully!${RESET}"
    echo -e "Obfuscation params used → Jc=$JC  Jmin=$JMIN  Jmax=$JMAX"

else
    echo -e "${RED}[!] Invalid selection.${RESET}"
    exit 1
fi

echo -e "${GREEN}"
echo "========================================"
echo "  Configuration completed successfully"
echo "  Tunnel will survive reboot"
echo "========================================"
echo -e "${RESET}"
