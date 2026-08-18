bash <(cat << 'EOF'
#!/bin/bash

clear
echo "===================================================="
echo "    Netplas Xray-Reality Automated Setup Script     "
echo "===================================================="
echo

read -p "لطفاً آی‌پی سرور خارج (Foreign Server IP) را وارد کنید: " IP_FOREIGN

if [ -z "$IP_FOREIGN" ]; then
    echo "خطا: آی‌پی وارد نشده است!"
    exit 1
fi

# ثابت‌ها و کلیدهای از پیش‌تایید شده
UUID="7f2b6886-4602-441b-a256-d31ca2a3fd74"
PUBLIC_KEY="juncreRBxxUYaV6PA1aQNPzyx4tS9MjeKpVcv5vtxy8"
SHORT_ID="7da10f5b"

echo "[+] در حال نصب و به‌روزرسانی Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

echo "[+] در حال تنظیم کانگفیگ Xray روی سرور ایران..."
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

# ذخیره قوانین iptables
apt-get install -y iptables-persistent > /dev/null 2>&1
netfilter-persistent save > /dev/null 2>&1

echo
echo "===================================================="
echo "         راه‌اندازی با موفقیت به پایان رسید!          "
echo "===================================================="
echo "حالا می‌توانید دستور زیر را برای تست اتصال اجرا کنید:"
echo "curl -x socks5://127.0.0.1:1080 http://104.16.132.229"
echo "===================================================="
EOF
)
