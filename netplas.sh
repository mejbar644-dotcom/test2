#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "  AmneziaWG Anti-Filter Tunnel v4.1"
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
    
    # پاکسازی ایمن IPTables
    iptables -F FORWARD 2>/dev/null
    iptables -t nat -F PREROUTING 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null
    
    echo -e "${GREEN}[+] Tunnel removed successfully!${RESET}"
    exit 0
fi

read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN
read -p "Enter AmneziaWG Port (Default 51820): " AWG_PORT
AWG_PORT=${AWG_PORT:-51820}

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

# حذف اینترفیس قبلی در صورت وجود
ip link del awg0 2>/dev/null

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server with AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "${YELLOW}[?] Please run the Foreign server script first.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY
    
    # دریافت مقادیر تصادفی H1 تا H4
    read -p "Enter H1 value from Foreign server: " H1
    read -p "Enter H2 value from Foreign server: " H2
    read -p "Enter H3 value from Foreign server: " H3
    read -p "Enter H4 value from Foreign server: " H4

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.2/30 dev awg0
    ip link set dev awg0 mtu 1360
    
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc 4 jmin 50 jmax 1000 s1 55 s2 75 h1 $H1 h2 $H2 h3 $H3 h4 $H4
    
    awg set awg0 peer "$FOREIGN_PUBKEY" endpoint "$IP_FOREIGN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    # تنظیمات صحیح IPTables در سرور ایران
    iptables -F FORWARD
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING

    # اجازه عبور به ترافیک تانل و لایه داخلی
    iptables -A INPUT -i awg0 -j ACCEPT
    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -A FORWARD -i $MAIN_INTERFACE -o awg0 -j ACCEPT
    iptables -A FORWARD -i awg0 -o $MAIN_INTERFACE -j ACCEPT

    # تنظیم MSS جهت جلوگیری از افت سرعت و عدم لود صفحات
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # استثنا کردن پورت تانل و فوروارد صحیح UDP/TCP به سرور خارج
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp --dport $AWG_PORT -j ACCEPT
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp ! --dport $AWG_PORT -j DNAT --to-destination 10.0.0.1
    
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Iran server configured successfully!${RESET}"
    echo -e "Your Iran Server Public Key: ${CYAN}$PubKey${RESET}"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server with AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    # تولید اعداد تصادفی ۳۲ بیتی برای هدرها
    H1=$(shuf -i 100000000-2147483647 -n 1)
    H2=$(shuf -i 100000000-2147483647 -n 1)
    H3=$(shuf -i 100000000-2147483647 -n 1)
    H4=$(shuf -i 100000000-2147483647 -n 1)

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${RESET}"
    echo -e "${YELLOW}--- Save these H-Header values for IRAN server setup ---${RESET}"
    echo -e "H1: ${CYAN}$H1${RESET}"
    echo -e "H2: ${CYAN}$H2${RESET}"
    echo -e "H3: ${CYAN}$H3${RESET}"
    echo -e "H4: ${CYAN}$H4${RESET}"
    echo -e "-------------------------------------------------------"
    read -p "Press Enter after you have saved these values..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.1/30 dev awg0
    ip link set dev awg0 mtu 1360
    
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc 4 jmin 50 jmax 1000 s1 55 s2 75 h1 $H1 h2 $H2 h3 $H3 h4 $H4
    
    awg set awg0 peer "$IRAN_PUBKEY" endpoint "$IP_IRAN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    # تنظیمات صحیح IPTables در سرور خارج
    iptables -F FORWARD
    iptables -t nat -F POSTROUTING

    iptables -A INPUT -i awg0 -j ACCEPT
    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Foreign server configured successfully!${RESET}"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${RESET}"
    exit 1
fi
