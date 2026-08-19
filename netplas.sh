#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "    Wstunnel Setup Script v2"
echo "===================================="
echo -e "${RESET}"

# نصب پیش‌نیازها و دانلود آخرین نسخه wstunnel
if ! command -v wstunnel &> /dev/null; then
    echo "[*] Downloading and installing wstunnel..."
    apt-get update
    apt-get install -y curl wget systemd
    
    # دانلود نسخه سازگار
    WSTUNNEL_URL="https://github.com/erebe/wstunnel/releases/download/v9.2.3/wstunnel-x86_64-linux"
    wget -q -O /usr/local/bin/wstunnel "$WSTUNNEL_URL" || {
        wget -q -O /usr/local/bin/wstunnel "https://github.com/erebe/wstunnel/releases/download/v5.1/wstunnel-linux-x64"
    }
    chmod +x /usr/local/bin/wstunnel
fi

echo "Select server role:"
echo "1 - FOREIGN Server (Server Mode - listens on port 443)"
echo "2 - IRAN Server (Client Mode - connects to Foreign)"
echo "3 - Uninstall Wstunnel"
read -p "Enter your choice (1, 2 or 3): " CHOICE

if [[ "$CHOICE" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN Server...${RESET}"
    
    # ایجاد سرویس سیستمی برای سرور خارج با ساختار صحیح نسخه جدید
    cat << 'EOF' > /etc/systemd/system/wstunnel-server.service
[Unit]
Description=Wstunnel Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel server --restrict-to 127.0.0.1:51820 0.0.0.0:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wstunnel-server
    echo -e "${GREEN}[+] Foreign Wstunnel server is running on port 443!${RESET}"

elif [[ "$CHOICE" == "2" ]]; then
    read -p "Enter FOREIGN server IP: " IP_FOREIGN
    
    echo -e "${YELLOW}[*] Configuring IRAN Server...${RESET}"
    
    # ایجاد سرویس سیستمی برای سرور ایران با سویچ remote-- صحیح
    cat << EOF > /etc/systemd/system/wstunnel-client.service
[Unit]
Description=Wstunnel Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel client -L udp://127.0.0.1:51820:127.0.0.1:51820 --remote wss://$IP_FOREIGN:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wstunnel-client
    echo -e "${GREEN}[+] Iran Wstunnel client is connected to Foreign server!${RESET}"
    echo -e "${CYAN}Tunnel is ready on localhost (127.0.0.1:51820).${RESET}"

elif [[ "$CHOICE" == "3" ]]; then
    systemctl stop wstunnel-server wstunnel-client 2>/dev/null
    rm -f /etc/systemd/system/wstunnel-server.service /etc/systemd/system/wstunnel-client.service
    rm -f /usr/local/bin/wstunnel
    systemctl daemon-reload
    echo -e "${GREEN}[+] Wstunnel removed successfully.${RESET}"
else
    echo -e "${RED}[!] Invalid choice.${RESET}"
    exit 1
fi
