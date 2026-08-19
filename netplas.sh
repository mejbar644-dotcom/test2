#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "     Hysteria 2 Tunnel Setup"
echo "===================================="
echo -e "${RESET}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run this script as root (sudo).${RESET}"
  exit 1
fi

echo "Select an option:"
echo "1 - IRAN Server Configuration (Client/Forwarder)"
echo "2 - FOREIGN Server Configuration (Server)"
echo "3 - Uninstall Hysteria 2"
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling Hysteria 2...${RESET}"
    systemctl stop hysteria-server hysteria-client 2>/dev/null
    systemctl disable hysteria-server hysteria-client 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-client.service
    rm -rf /etc/hysteria
    rm -f /usr/local/bin/hysteria
    echo -e "${GREEN}[+] Hysteria 2 removed successfully!${RESET}"
    exit 0
fi

# نصب خودکار هسته هیستاریا اگر نصب نباشد
if ! command -v hysteria &> /dev/null; then
    echo "[*] Installing Hysteria 2 binary..."
    bash <(curl -fsSL https://get.hy2.sh/) &>/dev/null
fi

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

if [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN Server...${RESET}"
    
    read -p "Enter Hysteria Port (Default 443): " HY_PORT
    HY_PORT=${HY_PORT:-443}
    
    read -p "Enter a secure password for tunnel: " HY_PASSWORD
    HY_PASSWORD=${HY_PASSWORD:-NetplasSecurePass2026}

    mkdir -p /etc/hysteria

    # تولید گواهینامه SSL خودامضا
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" 2>/dev/null

    # ساخت فایل کانفیگ سرور خارج
    cat << EOF > /etc/hysteria/config.yaml
listen: :$HY_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$HY_PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF

    # تنظیم سرویس سیستمی برای سرور خارج
    cat << EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server

    FOREIGN_IP=$(curl -s ifconfig.me)
    echo -e "${GREEN}[+] Foreign Server configured successfully!${RESET}"
    echo -e "Server IP: ${CYAN}$FOREIGN_IP${RESET}"
    echo -e "Port: ${CYAN}$HY_PORT${RESET}"
    echo -e "Password: ${CYAN}$HY_PASSWORD${RESET}"

elif [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN Server...${RESET}"

    read -p "Enter FOREIGN Server IP: " IP_FOREIGN
    read -p "Enter FOREIGN Server Port (Default 443): " HY_PORT
    HY_PORT=${HY_PORT:-443}
    read -p "Enter Tunnel Password (same as foreign): " HY_PASSWORD

    mkdir -p /etc/hysteria

    # ساخت فایل کانفیگ کلاینت در سرور ایران
    cat << EOF > /etc/hysteria/config.yaml
server: $IP_FOREIGN:$HY_PORT

auth:
  type: password
  password: "$HY_PASSWORD"

tls:
  sni: bing.com
  insecure: true

udpFragment: true

bandwidth:
  up: 100 mbps
  down: 100 mbps
EOF

    # تنظیم سرویس سیستمی برای سرور ایران
    cat << EOF > /etc/systemd/system/hysteria-client.service
[Unit]
Description=Hysteria 2 Client Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/config.yaml
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # فعال‌سازی فوروارد پورت‌ها از سرور ایران به سرور خارج با استفاده از iptables
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    iptables -t nat -F
    # هدایت ترافیک پورت‌های ورودی (به جز پورت‌های مدیریت مثل 22، 80، 10052) به سمت لوکال یا تونل
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 127.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -m multiport ! --dports 53 -j DNAT --to-destination 127.0.0.1
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    systemctl daemon-reload
    systemctl enable hysteria-client
    systemctl restart hysteria-client

    echo -e "${GREEN}[+] Iran Server configured successfully and traffic tunneled via Hysteria 2!${RESET}"

else
    echo -e "${RED}[!] Invalid selection.${RESET}"
    exit 1
fi
