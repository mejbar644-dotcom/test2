#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run this script as root (sudo).${RESET}"
  exit 1
fi

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "  AmneziaWG Anti-Filter Tunnel v3.3"
echo "===================================="
echo -e "${RESET}"

# بررسی نصب بودن amneziawg و iptables
if ! command -v awg &> /dev/null; then
    echo "[*] Installing AmneziaWG and iptables..."
    apt-get update
    apt-get install -y curl wget iptables iptables-persistent software-properties-common
    add-apt-repository -y ppa:amnezia/ppa &>/dev/null
    apt-get update
    apt-get install -y amneziawg amneziawg-tools
fi

echo "Select an option:"
echo "1 - IRAN Server Configuration"
echo "2 - FOREIGN Server Configuration"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

# رنج آی‌پی داخلی ثابت برای تونل
TUNNEL_IP_IRAN="172.28.14.2"
TUNNEL_IP_FOREIGN="172.28.14.1"

# مقادیر پنهان‌سازی ثابت و مقاوم در برابر DPI (باید در هر دو سرور دقیقاً یکسان باشد)
FIXED_JC=5
FIXED_JMIN=45
FIXED_JMAX=750
FIXED_S1=52
FIXED_S2=95
FIXED_H1=34851290
FIXED_H2=71520489
FIXED_H3=12948301
FIXED_H4=89234105

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up AmneziaWG tunnel...${RESET}"
    ip link set awg0 down 2>/dev/null
    ip link del awg0 2>/dev/null
    rm -rf /etc/amnezia
    iptables -t nat -D PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination $TUNNEL_IP_FOREIGN 2>/dev/null
    iptables -t nat -D PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination $TUNNEL_IP_FOREIGN 2>/dev/null
    iptables -t nat -F POSTROUTING
    sysctl -w net.ipv4.ip_forward=0
    echo -e "${GREEN}[+] Tunnel and all configurations removed successfully!${RESET}"
    exit 0
fi

read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN

read -p "Enter AmneziaWG Port (Default 51820): " AWG_PORT
AWG_PORT=${AWG_PORT:-51820}

# حذف اینترفیس قبلی در صورت وجود
ip link del awg0 2>/dev/null

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server with AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "${YELLOW}[?] Please run the Foreign server script first and copy its Public Key.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-amnezia.conf

    ip link add dev awg0 type amneziawg
    ip address add $TUNNEL_IP_IRAN/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc $FIXED_JC jmin $FIXED_JMIN jmax $FIXED_JMAX s1 $FIXED_S1 s2 $FIXED_S2 h1 $FIXED_H1 h2 $FIXED_H2 h3 $FIXED_H3 h4 $FIXED_H4
    
    awg set awg0 peer "$FOREIGN_PUBKEY" endpoint "$IP_FOREIGN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    # اعمال قوانین فوروارد و NAT با آی‌پی جدید تونل
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination $TUNNEL_IP_FOREIGN
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination $TUNNEL_IP_FOREIGN
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
    netfilter-persistent save

    echo -e "${GREEN}[+] Iran server configured successfully with fixed anti-filter parameters!${RESET}"
    echo "Your Iran Server Public Key: $PubKey"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server with AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${RESET}"
    read -p "Press Enter after you have saved this key..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-amnezia.conf

    ip link add dev awg0 type amneziawg
    ip address add $TUNNEL_IP_FOREIGN/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc $FIXED_JC jmin $FIXED_JMIN jmax $FIXED_JMAX s1 $FIXED_S1 s2 $FIXED_S2 h1 $FIXED_H1 h2 $FIXED_H2 h3 $FIXED_H3 h4 $FIXED_H4
    
    awg set awg0 peer "$IRAN_PUBKEY" endpoint "$IP_IRAN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
    netfilter-persistent save

    echo -e "${GREEN}[+] Foreign server configured successfully with fixed anti-filter parameters!${RESET}"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${RESET}"
    exit 1
fi
