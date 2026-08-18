bash <(cat << 'EOF'
#!/bin/bash

clear
echo "===================================================="
echo "      Netplas Unified Xray-Reality Setup Script     "
echo "===================================================="
echo

echo "این سرور چه نقشی دارد؟"
echo "1) سرور خارج (Foreign Server)"
echo "2) سرور ایران (Iran Server)"
read -p "انتخاب شما (1 یا 2): " ROLE

# نصب Xray
echo "[+] در حال نصب و به‌روزرسانی Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

if [ "$ROLE" == "1" ]; then
    # تنظیمات سرور خارج
    echo "[+] در حال تولید کلیدهای امنیتی..."
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Password" | awk '{print $3}')
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)

    cat << INNER_EOF > /usr/local/etc/xray/config.json
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
            "id": "$UUID"
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
INNER_EOF

    systemctl restart xray
    systemctl enable xray > /dev/null 2>&1

    echo
    echo "===================================================="
    echo "      سرور خارج با موفقیت تنظیم شد!                "
    echo "===================================================="
    echo "این مقادیر را یادداشت کنید تا در سرور ایران وارد کنید:"
    echo "----------------------------------------------------"
    echo -e "UUID: \e[32m$UUID\e[0m"
    echo -e "Public Key: \e[32m$PUBLIC_KEY\e[0m"
    echo -e "Short ID: \e[32m$SHORT_ID\e[0m"
    echo "===================================================="

elif [ "$ROLE" == "2" ]; then
    # تنظیمات سرور ایران
    read -p "آی‌پی سرور خارج (Foreign Server IP): " IP_FOREIGN
    read -p "مقدار UUID: " UUID
    read -p "مقدار Public Key: " PUBLIC_KEY
    read -p "مقدار Short ID: " SHORT_ID

    if [ -z "$IP_FOREIGN" ] || [ -z "$UUID" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
        echo "خطا: تمام مقادیر باید وارد شوند!"
        exit 1
    fi

    MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

    cat << INNER_EOF > /usr/local/etc/xray/config.json
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
INNER_EOF

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf

    systemctl restart xray
    systemctl enable xray > /dev/null 2>&1

    echo "[+] در حال اعمال قوانین NAT و IPTables..."
    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 127.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 127.0.0.1
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    apt-get install -y iptables-persistent > /dev/null 2>&1
    netfilter-persistent save > /dev/null 2>&1

    echo
    echo "===================================================="
    echo "      سرور ایران با موفقیت تنظیم شد!               "
    echo "===================================================="
    echo "دستور تست اتصال:"
    echo "curl -x socks5://127.0.0.1:1080 http://104.16.132.229"
    echo "===================================================="
else
    echo "انتخاب نامعتبر!"
fi
EOF
)
