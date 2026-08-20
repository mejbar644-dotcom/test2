#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "========================================"
echo "   AmneziaWG Anti-Filter Tunnel v4.1"
echo "   (Runtime - No Persistent Config)"
echo "========================================"
echo -e "${RESET}"

# تولید پارامترهای تصادفی obfuscation
generate_random_params() {
    JC=$((3 + RANDOM % 5))
    JMIN=$((40 + RANDOM % 50))
    JMAX=$((JMIN + 300 + RANDOM % 700))
    S1=$((40 + RANDOM % 70))
    S2=$((40 + RANDOM % 70))
    H1=$((RANDOM * RANDOM + RANDOM))
    H2=$((RANDOM * RANDOM + RANDOM))
    H3=$((RANDOM * RANDOM + RANDOM))
    H4=$((RANDOM * RANDOM + RANDOM))
}

# بررسی و نصب AmneziaWG
if ! command -v awg &>/dev/null; then
    echo -e "${YELLOW}[*] Installing AmneziaWG...${RESET}"
    apt-get update -qq
    apt-get install -y curl wget iptables software-properties-common
    add-apt-repository -y ppa:amnezia/ppa &>/dev/null || true
    apt-get update -qq
    apt-get install -y amneziawg amneziawg-tools
fi

# منو
echo "Select an option:"
echo "1 - IRAN Server Configuration"
echo "2 - FOREIGN Server Configuration"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Removing tunnel...${RESET}"
    ip link set awg0 down 2>/dev/null || true
    ip link del awg0 2>/dev/null || true
    rm -rf /etc/amnezia
    iptables -t nat -F
    iptables -t nat -X
    iptables -F
    iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    echo -e "${GREEN}[+] Tunnel removed successfully.${RESET}"
    exit 0
fi

read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN
read -p "Enter AmneziaWG Port (Default 51820): " AWG_PORT
AWG_PORT=${AWG_PORT:-51820}

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
[[ -z "$MAIN_INTERFACE" ]] && { echo -e "${RED}[!] Main interface not found${RESET}"; exit 1; }

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

    echo -e "${YELLOW}[?] First run FOREIGN server and copy its Public Key.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.2/30 dev awg0

    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc $JC jmin $JMIN jmax $JMAX s1 $S1 s2 $S2 \
        h1 $H1 h2 $H2 h3 $H3 h4 $H4

    awg set awg0 peer "$FOREIGN_PUBKEY" endpoint "$IP_FOREIGN:$AWG_PORT" \
        allowed-ips 0.0.0.0/0 persistent-keepalive 35

    ip link set dev awg0 up

    # قوانین NAT
    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT

    echo -e "${GREEN}[+] Iran server configured successfully!${RESET}"
    echo -e "Iran Public Key: ${CYAN}$PubKey${RESET}"
    echo -e "Obfuscation → Jc=$JC Jmin=$JMIN Jmax=$JMAX"

elif [[ "$LOCATION" == "2" ]]; then
    # ==================== سرور خارج ====================
    echo -e "${YELLOW}[*] Configuring FOREIGN server...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key

    echo -e "Foreign Public Key: ${CYAN}$PubKey${RESET}"
    read -p "Press Enter after saving this key..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.1/30 dev awg0

    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc $JC jmin $JMIN jmax $JMAX s1 $S1 s2 $S2 \
        h1 $H1 h2 $H2 h3 $H3 h4 $H4

    awg set awg0 peer "$IRAN_PUBKEY" endpoint "$IP_IRAN:$AWG_PORT" \
        allowed-ips 0.0.0.0/0 persistent-keepalive 35

    ip link set dev awg0 up

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Foreign server configured successfully!${RESET}"
    echo -e "Obfuscation → Jc=$JC Jmin=$JMIN Jmax=$JMAX"

else
    echo -e "${RED}[!] Invalid option${RESET}"
    exit 1
fi

echo -e "${GREEN}"
echo "========================================"
echo "  Done (Runtime mode - no persistent)"
echo "========================================"
echo -e "${RESET}"
