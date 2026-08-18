#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "        Netplas Xray-Reality Tunnel"
echo "===================================="
echo -e "${RESET}"

# بررسی و نصب پکیج‌های اولیه و Xray
if ! command -v xray &> /dev/null; then
    echo "[*] Installing Xray and dependencies..."
    apt-get update
    apt-get install -y curl wget iptables ufw jq
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

echo "Select an option:"
echo "1 - FOREIGN Server Configuration"
echo "2 - IRAN Server Configuration"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up Xray and rules...${RESET}"
    systemctl stop xray
    systemctl disable xray
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

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server...${RESET}"
    
    # تولید کلیدها و UUID
    UUID=$(xray uuid)
    KEYPAIR=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "Private" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Public" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 4)
    
    echo -e "${GREEN}--- Save these credentials for the Iran server ---${RESET}"
    echo -e "UUID: ${CYAN}$UUID${RESET}"
    echo -e "Public Key: ${CYAN}$PUBLIC_KEY${RESET}"
    echo -e "Short ID: ${CYAN}$SHORT_ID${RESET}"
    echo -e "${GREEN-----------------------------------------------${RESET}"

    # ایجاد کانفیگ سرور خارج
    cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "dl.google.com:443",
          "xver": 0,
          "serverNames": [
            "dl.google.com",
            "www.google.com"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    systemctl restart xray
    systemctl enable xray
    echo -e "${GREEN}[+] Foreign server configured and Xray started successfully!${RESET}"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server...${RESET}"

    read -p "Enter FOREIGN server IP: " IP_FOREIGN
    read -p "Enter UUID (from Foreign server): " UUID
    read -p "Enter PUBLIC KEY (from Foreign server): " PUBLIC_KEY
    read -p "Enter SHORT ID (from Foreign server): " SHORT_ID

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # ایجاد کانفیگ سرور ایران (کلاینت)
    cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$IP_FOREIGN",
            "port": 443,
            "users": [
              {
                "id": "$UUID",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "publicKey": "$PUBLIC_KEY",
          "fingerprint": "chrome",
          "serverName": "dl.google.com",
          "shortId": "$SHORT_ID"
        }
      }
    }
  ]
}
EOF

    systemctl restart xray
    systemctl enable xray

    # تنظیمات iptables برای هدایت ترافیک (حفظ پورت‌های 22، 80 و 10052)
    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 127.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 127.0.0.1
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Iran server configured successfully with Reality tunnel!${RESET}"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${RESET}"
    exit 1
fi
