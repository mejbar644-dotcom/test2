#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "  AmneziaWG Anti-Filter Tunnel v3.1"
echo "  (Improved Obfuscation for 2026)"
echo "===================================="
echo -e "${RESET}"

# بررسی نصب بودن amneziawg و iptables
if ! command -v awg &> /dev/null; then
    echo "[*] Installing AmneziaWG and iptables..."
    apt-get update
    apt-get install -y curl wget iptables software-properties-common
    add-apt-repository -y ppa:amnezia/ppa &>/dev/null
    apt-get update
    apt-get install -y amneziawg amneziawg-tools
fi

echo "Select an option:"
echo "1 - IRAN Server Configuration"
echo "2 - FOREIGN Server Configuration"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up AmneziaWG tunnel...${RESET}"
    ip link set awg0 down 2>/dev/null
    ip link del awg0 2>/dev/null
    rm -rf /etc/amnezia
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
    echo -e "${GREEN}[+] Tunnel and all configurations removed successfully!${RESET}"
    exit 0
fi

read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN

# پورت پیشنهادی پایین‌تر برای دور زدن محدودیت‌های ISP
read -p "Enter AmneziaWG Port (Recommended: 585 or 1234 | Default 51820): " AWG_PORT
AWG_PORT=${AWG_PORT:-51820}

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

# حذف اینترفیس قبلی در صورت وجود
ip link del awg0 2>/dev/null

# ========== پارامترهای obfuscation بهبود یافته ==========
# این مقادیر روی هر دو سرور باید دقیقاً یکسان باشند
JC=6
JMIN=45
JMAX=280
S1=55
S2=72
H1=84729103
H2=19283746
H3=56473829
H4=91827364
# I1 برای mimic بهتر (DNS-like)
I1="<r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>"

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server with improved AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "${YELLOW}[?] Please run the Foreign server script first and copy its Public Key.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # ساخت اینترفیس
    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.2/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key

    # تنظیم با پارامترهای جدید obfuscation
    awg set awg0 \
        listen-port $AWG_PORT \
        private-key /etc/amnezia/amneziawg/private.key \
        jc $JC \
        jmin $JMIN \
        jmax $JMAX \
        s1 $S1 \
        s2 $S2 \
        h1 $H1 \
        h2 $H2 \
        h3 $H3 \
        h4 $H4 \
        i1 "$I1"

    awg set awg0 peer "$FOREIGN_PUBKEY" endpoint "$IP_FOREIGN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    # پاکسازی و اعمال NAT (حفظ استثنای پورت‌های مهم)
    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,443,10052 -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    # فوروارد
    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT

    echo -e "${GREEN}[+] Iran server configured successfully with improved anti-filter tunnel!${RESET}"
    echo "Your Iran Server Public Key: $PubKey"
    echo -e "${CYAN}Parameters used: Jc=$JC Jmin=$JMIN Jmax=$JMAX S1=$S1 S2=$S2${RESET}"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server with improved AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${RESET}"
    read -p "Press Enter after you have saved this key..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # ساخت اینترفیس
    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.1/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    chmod 600 /etc/amnezia/amneziawg/private.key

    # تنظیم با همان پارامترهای obfuscation
    awg set awg0 \
        listen-port $AWG_PORT \
        private-key /etc/amnezia/amneziawg/private.key \
        jc $JC \
        jmin $JMIN \
        jmax $JMAX \
        s1 $S1 \
        s2 $S2 \
        h1 $H1 \
        h2 $H2 \
        h3 $H3 \
        h4 $H4 \
        i1 "$I1"

    awg set awg0 peer "$IRAN_PUBKEY" endpoint "$IP_IRAN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Foreign server configured successfully with improved anti-filter tunnel!${RESET}"
    echo -e "${CYAN}Parameters used: Jc=$JC Jmin=$JMIN Jmax=$JMAX S1=$S1 S2=$S2${RESET}"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${RESET}"
    exit 1
fi

echo ""
echo -e "${YELLOW}[*] Checking interface status...${RESET}"
ip a show awg0
echo ""
echo -e "${YELLOW}[*] Checking peers...${RESET}"
awg show
echo ""
echo -e "${GREEN}Done! Test with: ping 10.0.0.1 (from Iran) or ping 10.0.0.2 (from Foreign)${RESET}"
