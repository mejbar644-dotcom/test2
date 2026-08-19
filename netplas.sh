#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "    Wstunnel Setup Script v5"
echo "===================================="
echo -e "${RESET}"

# نصب پیش‌نیازها و دانلود آخرین نسخه معتبر wstunnel
if ! command -v wstunnel &> /dev/null; then
    echo "[*] Installing wstunnel..."
    apt-get update && apt-get install -y curl wget systemd
    
    wget -q -O /tmp/wstunnel.tar.gz "https://github.com/erebe/wstunnel/releases/download/v10.6.2/wstunnel_10.6.2_linux_amd64.tar.gz"
    tar -xzf /tmp/wstunnel.tar.gz -C /tmp/
    mv /tmp/wstunnel /usr/local/bin/wstunnel
    chmod +x /usr/local/bin/wstunnel
    rm -f /tmp/wstunnel.tar.gz
fi

echo "Select server role:"
echo "1 - FOREIGN Server (Server Mode)"
echo "2 - IRAN Server (Client Mode)"
echo "3 - Uninstall Wstunnel"
read -p "Enter your choice (1, 2 or 3): " CHOICE

if [[ "$CHOICE" == "1" ]]; then
    read -p "Enter local port for tunnel (Default 51820): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-51820}
    
    echo -e "${YELLOW}[*] Configuring FOREIGN Server...${RESET}"
    cat << EOF > /etc/systemd/system/wstunnel-server.service
[Unit]
Description=Wstunnel Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel server --restrict-to 127.0.0.1:$LOCAL_PORT 0.0.0.0:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl restart wstunnel-server && systemctl enable wstunnel-server
    echo -e "${GREEN}[+] Foreign server is running on port 443!${RESET}"

elif [[ "$CHOICE" == "2" ]]; then
    read -p "Enter FOREIGN server IP: " IP_FOREIGN
    read -p "Enter port for local tunnel (Default 51820): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-51820}
    
    echo -e "${YELLOW}[*] Configuring IRAN Server...${RESET}"
    cat << EOF > /etc/systemd/system/wstunnel-client.service
[Unit]
Description=Wstunnel Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel client -L udp://127.0.0.1:$LOCAL_PORT:127.0.0.1:$LOCAL_PORT ws://$IP_FOREIGN:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl restart wstunnel-client && systemctl enable wstunnel-client
    echo -e "${GREEN}[+] Iran client connected to $IP_FOREIGN using ws:// protocol!${RESET}"

elif [[ "$CHOICE" == "3" ]]; then
    systemctl stop wstunnel-server wstunnel-client 2>/dev/null
    rm -f /etc/systemd/system/wstunnel-server.service /etc/systemd/system/wstunnel-client.service /usr/local/bin/wstunnel
    systemctl daemon-reload
    echo -e "${GREEN}[+] Wstunnel removed.${RESET}"
else
    echo -e "${RED}[!] Invalid choice.${RESET}"
fi
