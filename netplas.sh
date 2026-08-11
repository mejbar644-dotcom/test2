#!/bin/bash

CYAN='\033[1;36m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
PURPLE='\033[1;35m'
NC='\033[0m'

clear
echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║            GitHub: Netplas                 ║${NC}"
echo -e "${CYAN}║     AmneziaWG Anti-Filter Tunnel v4.4      ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run this script as root (sudo)!${NC}"
  exit 1
fi

if ! command -v awg &> /dev/null || ! command -v awg-keygen &> /dev/null; then
    echo -e "${YELLOW}[*] Installing AmneziaWG and dependencies...${NC}"
    apt-get update
    apt-get install -y curl wget iptables software-properties-common
    add-apt-repository -y ppa:amnezia/ppa &>/dev/null
    apt-get update
    apt-get install -y amneziawg amneziawg-tools
fi

echo -e "${PURPLE}Select an option:${NC}"
echo -e "  ${GREEN}1${NC} - IRAN Server Configuration"
echo -e "  ${GREEN}2${NC} - FOREIGN Server Configuration"
echo -e "  ${RED}3${NC} - Uninstall & Remove Tunnel Completely"
echo ""
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up AmneziaWG tunnel...${NC}"
    systemctl stop awg-quick@awg0 2>/dev/null
    systemctl disable awg-quick@awg0 2>/dev/null
    rm -rf /etc/amnezia/amneziawg
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    sysctl -w net.ipv4.ip_forward=0
    echo -e "${GREEN}[+] Tunnel and all configurations removed successfully!${NC}"
    exit 0
fi

read -p "Enter IRAN server public IP: " IP_IRAN
read -p "Enter FOREIGN server public IP: " IP_FOREIGN
read -p "Enter AmneziaWG Port (Default 443): " AWG_PORT
AWG_PORT=${AWG_PORT:-443}

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
CURRENT_SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}

systemctl stop awg-quick@awg0 2>/dev/null
ip link del awg0 2>/dev/null
mkdir -p /etc/amnezia/amneziawg

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server permanently...${NC}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    # نمایش کلید عمومی در همان ابتدا تا از دست نرود
    echo ""
    echo -e "${GREEN}==================================================${NC}"
    echo -e "Your Iran Server Public Key is: ${CYAN}$PubKey${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.0.0.2/30
PrivateKey = $PrivKey
ListenPort = $AWG_PORT
MTU = 1280
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 55
S2 = 75
H1 = 12345678
H2 = 87654321
H3 = 13579246
H4 = 24681357

[Peer]
PublicKey = $FOREIGN_PUBKEY
Endpoint = $IP_FOREIGN:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports ${CURRENT_SSH_PORT},22,80,443,10052 -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -m multiport ! --dports ${AWG_PORT} -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    systemctl enable --now awg-quick@awg0

    echo -e "${GREEN}[+] Iran server configured and running permanently!${NC}"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server permanently...${NC}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${NC}"
    echo ""
    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.0.0.1/30
PrivateKey = $PrivKey
ListenPort = $AWG_PORT
MTU = 1280
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 55
S2 = 75
H1 = 12345678
H2 = 87654321
H3 = 13579246
H4 = 24681357

[Peer]
PublicKey = $IRAN_PUBKEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    systemctl enable --now awg-quick@awg0

    echo -e "${GREEN}[+] Foreign server configured and running permanently!${NC}"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${NC}"
    exit 1
fi
