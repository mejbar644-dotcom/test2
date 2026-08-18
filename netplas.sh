bash <(cat << 'EOF'
#!/bin/bash

clear
echo "===================================================="
echo "    Netplas Xray-Reality Foreign Server Setup       "
echo "===================================================="
echo

echo "[+] در حال نصب و به‌روزرسانی Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

echo "[+] در حال تولید کلیدهای امنیتی X25519..."
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Password" | awk '{print $3}')
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 4)

echo "[+] در حال تنظیم کانفیگ Xray..."
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
echo "      تنظیمات سرور خارج با موفقیت انجام شد!         "
echo "===================================================="
echo "این اطلاعات را برای سرور ایران نیاز دارید:"
echo "----------------------------------------------------"
echo -e "UUID: \e[32m$UUID\e[0m"
echo -e "Public Key: \e[32m$PUBLIC_KEY\e[0m"
echo -e "Short ID: \e[32m$SHORT_ID\e[0m"
echo "===================================================="
EOF
)
