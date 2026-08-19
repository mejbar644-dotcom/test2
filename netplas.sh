#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "        GitHub: Netplas"
echo "  AmneziaWG + Wstunnel Tunnel v4"
echo "===================================="
echo -e "${RESET}"

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run this script as root.${RESET}"
  exit 1
fi

# بررسی و نصب پیش‌نیازها (AmneziaWG و Wstunnel)
if ! command -v awg &> /dev/null || ! command -v wstunnel &> /dev/null; then
    echo "[*] Installing dependencies (AmneziaWG, Wstunnel, iptables)..."
    apt-get update
    apt-get install -y curl wget iptables software-properties-common
    add-apt-repository -y ppa:amnezia/ppa &>/dev/null
    apt-get update
    apt-get install -y amneziawg amneziawg-tools

    # نصب خودکار wstunnel (آخرین نسخه پایدار)
    WST_VER="10.6.2"
    wget -qO /tmp/wstunnel.tar.gz "https://github.com/erebe/wstunnel/releases/download/v${WST_VER}/wstunnel_${WST_VER}_linux_amd64.tar.gz"
    tar -xzf /tmp/wstunnel.tar.gz -C /tmp
    mv /tmp/wstunnel /usr/local/bin/
    chmod +x /usr/local/bin/wstunnel
    rm -rf /tmp/wstunnel.tar.gz
fi

echo "Select an option:"
echo "1 - IRAN Server Configuration"
echo "2 - FOREIGN Server Configuration"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up AmneziaWG + Wstunnel tunnel...${RESET}"
    systemctl stop wstunnel-client wstunnel-server 2>/dev/null
    systemctl disable wstunnel-client wstunnel-server 2>/dev/null
    rm -f /etc/systemd/system/wstunnel-client.service /etc/systemd/system/wstunnel-server.service
    systemctl daemon-reload
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

AWG_PORT=51950
WST_PORT=8443
MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

# حذف اینترفیس و سرویس‌های قبلی
ip link del awg0 2>/dev/null
systemctl stop wstunnel-client wstunnel-server 2>/dev/null

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server with AmneziaWG + Wstunnel Client...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "${YELLOW}[?] Please run the Foreign server script first and copy its Public Key.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # ساخت سرویس systemd برای Wstunnel Client (اتصال UDP داخلی به وب‌سوکت سرور خارج روی پورت 8443)
    cat << EOF > /etc/systemd/system/wstunnel-client.service
[Unit]
Description=Wstunnel Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel client -L udp://${AWG_PORT}:127.0.0.1:${AWG_PORT} ws://${IP_FOREIGN}:${WST_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wstunnel-client
    systemctl start wstunnel-client

    # ساخت اینترفیس امنزیا وایرگارد
    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.2/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc 4 jmin 50 jmax 1000 s1 55 s2 75 h1 12345678 h2 87654321 h3 13579246 h4 24681357
    
    # اندپوینت محلی برای عبور از طریق wstunnel
    awg set awg0 peer "$FOREIGN_PUBKEY" endpoint "127.0.0.1:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    # تنظیمات iptables
    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052,${WST_PORT} -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Iran server configured successfully with AmneziaWG + Wstunnel!${RESET}"
    echo "Your Iran Server Public Key: $PubKey"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server with AmneziaWG + Wstunnel Server...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${RESET}"
    read -p "Press Enter after you have saved this key..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # ساخت سرویس systemd برای Wstunnel Server (گوش دادن روی پورت 8443 و هدایت به پورت امنزیا)
    cat << EOF > /etc/systemd/system/wstunnel-server.service
[Unit]
Description=Wstunnel Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel server -- --port ${WST_PORT} udp://127.0.0.1:${AWG_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wstunnel-server
    systemctl start wstunnel-server

    # ساخت اینترفیس امنزیا وایرگارد
    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.1/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc 4 jmin 50 jmax 1000 s1 55 s2 75 h1 12345678 h2 87654321 h3 13579246 h4 24681357
    
    awg set awg0 peer "$IRAN_PUBKEY" endpoint "127.0.0.1:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Foreign server configured successfully with AmneziaWG + Wstunnel!${RESET}"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${RESET}"
    exit 1
fi
