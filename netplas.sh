#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "          GitHub: Netplas"
echo "  AmneziaWG Anti-Filter Tunnel v3"
echo "  + Auto-Accounting Web Panel"
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
echo "2 - FOREIGN Server Configuration (+ Web Panel)"
echo "3 - Uninstall & Remove Tunnel"
read -p "Enter your choice (1, 2 or 3): " LOCATION

if [[ "$LOCATION" == "3" ]]; then
    echo -e "${RED}[*] Uninstalling and cleaning up AmneziaWG tunnel & Panel...${RESET}"
    ip link set awg0 down 2>/dev/null
    ip link del awg0 2>/dev/null
    rm -rf /etc/amnezia
    systemctl stop tunnelpanel 2>/dev/null
    systemctl disable tunnelpanel 2>/dev/null
    rm -f /etc/systemd/system/tunnelpanel.service
    rm -rf /opt/tunnel-panel
    systemctl daemon-reload
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
    echo -e "${GREEN}[+] Tunnel and Panel removed successfully!${RESET}"
    exit 0
fi

read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN

read -p "Enter AmneziaWG Port (Default 51820): " AWG_PORT
AWG_PORT=${AWG_PORT:-51820}

MAIN_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

ip link del awg0 2>/dev/null

if [[ "$LOCATION" == "1" ]]; then
    echo -e "${YELLOW}[*] Configuring IRAN server with AmneziaWG...${RESET}"

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "${YELLOW}[?] Please run the Foreign server script first and copy its Public Key.${RESET}"
    read -p "Enter FOREIGN server Public Key: " FOREIGN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.2/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc 4 jmin 50 jmax 1000 s1 55 s2 75 h1 12345678 h2 87654321 h3 13579246 h4 24681357
    
    awg set awg0 peer "$FOREIGN_PUBKEY" endpoint "$IP_FOREIGN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    iptables -t nat -F
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p tcp -m multiport ! --dports 22,80,10052 -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A PREROUTING -i $MAIN_INTERFACE -p udp -j DNAT --to-destination 10.0.0.1
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    echo -e "${GREEN}[+] Iran server configured successfully with anti-filter tunnel!${RESET}"
    echo "Your Iran Server Public Key (give this to foreign if needed): $PubKey"

elif [[ "$LOCATION" == "2" ]]; then
    echo -e "${YELLOW}[*] Configuring FOREIGN server with AmneziaWG & Smart Panel...${RESET}"

    # نصب پیش‌نیازهای پنل پایتون
    apt-get install -y python3 python3-flask sqlite3

    PrivKey=$(awg genkey)
    PubKey=$(echo "$PrivKey" | awg pubkey)

    echo -e "Your Foreign Server Public Key is: ${CYAN}$PubKey${RESET}"
    read -p "Press Enter after you have saved this key..."

    read -p "Enter IRAN server Public Key: " IRAN_PUBKEY

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    ip link add dev awg0 type amneziawg
    ip address add 10.0.0.1/30 dev awg0
    mkdir -p /etc/amnezia/amneziawg
    echo "$PrivKey" > /etc/amnezia/amneziawg/private.key
    
    awg set awg0 listen-port $AWG_PORT private-key /etc/amnezia/amneziawg/private.key \
        jc 4 jmin 50 jmax 1000 s1 55 s2 75 h1 12345678 h2 87654321 h3 13579246 h4 24681357
    
    awg set awg0 peer "$IRAN_PUBKEY" endpoint "$IP_IRAN:$AWG_PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set dev awg0 up

    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

    # ==========================================
    # نصب وب‌پنل مدیریت پورت و حجم دهی روی سرور خارج
    # ==========================================
    echo -e "${YELLOW}[*] Installing Smart Accounting Web Panel...${RESET}"
    mkdir -p /opt/tunnel-panel

cat << 'EOF' > /opt/tunnel-panel/app.py
import sqlite3, threading, time, subprocess
from flask import Flask, render_template_string, request, redirect, url_for, session

app = Flask(__name__)
app.secret_key = 'jbar_secure_key'
DB_PATH = '/opt/tunnel-panel/panel.db'

# اطلاعات ورود
ADMIN_USER = 'jbar'
ADMIN_PASS = 'jbar'

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT, port INTEGER, 
        allocated_gb REAL, used_gb REAL, status TEXT, last_bytes INTEGER
    )''')
    conn.commit()
    conn.close()

init_db()

def run_cmd(cmd):
    try: return subprocess.check_output(cmd, shell=True).decode('utf-8')
    except: return ""

def update_traffic():
    while True:
        try:
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("SELECT id, port, allocated_gb, used_gb, status, last_bytes FROM users WHERE status='active'")
            users = c.fetchall()
            
            in_stats = run_cmd("iptables -xnvL INPUT")
            out_stats = run_cmd("iptables -xnvL OUTPUT")
            
            for u in users:
                uid, port, allocated, used, status, last_bytes = u
                port_str = f"dpt:{port}"
                sport_str = f"spt:{port}"
                
                # محاسبه مجموع بایت‌های ورودی و خروجی برای پورت
                total_in = sum([int(l.split()[1]) for l in in_stats.split('\n') if port_str in l and "ACCEPT" in l])
                total_out = sum([int(l.split()[1]) for l in out_stats.split('\n') if sport_str in l and "ACCEPT" in l])
                
                current_total = total_in + total_out
                delta = current_total - last_bytes
                if current_total < last_bytes: delta = current_total
                    
                if delta > 0:
                    new_used = used + (delta / 1073741824.0)
                    if new_used >= allocated:
                        # اعمال مسدودی روی فایروال
                        for proto in ['tcp', 'udp']:
                            run_cmd(f"iptables -I INPUT -p {proto} --dport {port} -j DROP")
                            run_cmd(f"iptables -I OUTPUT -p {proto} --sport {port} -j DROP")
                        c.execute("UPDATE users SET status='suspended', used_gb=?, last_bytes=? WHERE id=?", (new_used, current_total, uid))
                    else:
                        c.execute("UPDATE users SET used_gb=?, last_bytes=? WHERE id=?", (new_used, current_total, uid))
            conn.commit()
            conn.close()
        except: pass
        time.sleep(30)

threading.Thread(target=update_traffic, daemon=True).start()

HTML_TEMPLATE = """
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><title>پنل اختصاصی jbar</title>
<style>
body { font-family: Tahoma; background: #0f172a; color: #f8fafc; padding: 20px; }
.container { max-width: 900px; margin: auto; background: #1e293b; padding: 20px; border-radius: 10px; }
h1, h2 { color: #38bdf8; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; }
th, td { padding: 12px; border-bottom: 1px solid #334155; text-align: center; }
th { background: #334155; }
input, button { padding: 10px; margin: 5px; border-radius: 5px; border: none; }
input { background: #0f172a; color: #fff; border: 1px solid #475569; }
button { background: #0284c7; color: white; cursor: pointer; }
.suspended { color: #ef4444; font-weight: bold; }
.active { color: #22c55e; font-weight: bold; }
</style></head><body>
<div class="container">
    <h1>🚀 پنل مدیریت حجم پورت‌ها - jbar</h1>
    <a href="/logout" style="color:#ef4444; float:left;">خروج</a>
    <form action="/add" method="POST">
        <input type="text" name="username" placeholder="نام مشتری" required>
        <input type="number" name="port" placeholder="پورت (مثال: 2053)" required>
        <input type="number" step="0.1" name="allocated" placeholder="حجم (GB)" required>
        <button type="submit">➕ ساخت پورت</button>
    </form>
    <table>
        <tr><th>کاربر</th><th>پورت</th><th>حجم مجاز</th><th>مصرف شده</th><th>وضعیت</th><th>عملیات</th></tr>
        {% for u in users %}
        <tr>
            <td>{{ u[1] }}</td><td>{{ u[2] }}</td><td>{{ u[3] }} GB</td>
            <td>{{ "%.2f"|format(u[4]) }} GB</td>
            <td class="{{ u[5] }}">{{ 'فعال' if u[5] == 'active' else 'مسدود (اتمام حجم)' }}</td>
            <td><a href="/delete/{{ u[0] }}"><button style="background: #ef4444;">حذف</button></a></td>
        </tr>
        {% endfor %}
    </table>
</div></body></html>
"""

LOGIN_TEMPLATE = """
<!DOCTYPE html><html lang="fa" dir="rtl"><head><title>ورود</title>
<style>body{background:#0f172a;color:#fff;text-align:center;margin-top:100px;font-family:Tahoma;}
input,button{padding:10px;margin:5px;}</style></head>
<body><h2>ورود به پنل</h2><form method="POST">
<input name="user" placeholder="نام کاربری"><br>
<input type="password" name="pass" placeholder="رمز عبور"><br>
<button type="submit">ورود</button></form></body></html>
"""

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('user') == ADMIN_USER and request.form.get('pass') == ADMIN_PASS:
            session['logged_in'] = True
            return redirect(url_for('index'))
    return render_template_string(LOGIN_TEMPLATE)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.before_request
def check_auth():
    if not session.get('logged_in') and request.endpoint != 'login':
        return redirect(url_for('login'))

@app.route('/')
def index():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT * FROM users")
    users = c.fetchall()
    conn.close()
    return render_template_string(HTML_TEMPLATE, users=users)

@app.route('/add', methods=['POST'])
def add():
    u, p, a = request.form['username'], request.form['port'], request.form['allocated']
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("INSERT INTO users (username, port, allocated_gb, used_gb, status, last_bytes) VALUES (?, ?, ?, 0, 'active', 0)", (u, p, a))
    conn.commit()
    conn.close()
    
    # ساخت رول‌های محاسبه در فایروال (ایجاد شمارنده)
    for proto in ['tcp', 'udp']:
        run_cmd(f"iptables -I INPUT -p {proto} --dport {p} -j ACCEPT")
        run_cmd(f"iptables -I OUTPUT -p {proto} --sport {p} -j ACCEPT")
    return redirect(url_for('index'))

@app.route('/delete/<int:uid>')
def delete(uid):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT port FROM users WHERE id=?", (uid,))
    res = c.fetchone()
    if res:
        port = res[0]
        # پاکسازی قوانین فایروال
        for proto in ['tcp', 'udp']:
            run_cmd(f"iptables -D INPUT -p {proto} --dport {port} -j ACCEPT")
            run_cmd(f"iptables -D OUTPUT -p {proto} --sport {port} -j ACCEPT")
            run_cmd(f"iptables -D INPUT -p {proto} --dport {port} -j DROP")
            run_cmd(f"iptables -D OUTPUT -p {proto} --sport {port} -j DROP")
        c.execute("DELETE FROM users WHERE id=?", (uid,))
        conn.commit()
    conn.close()
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

    # ایجاد سرویس برای اجرای دائمی پنل
cat << 'EOF' > /etc/systemd/system/tunnelpanel.service
[Unit]
Description=JBAR Tunnel Traffic Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/tunnel-panel
ExecStart=/usr/bin/python3 /opt/tunnel-panel/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tunnelpanel
    systemctl start tunnelpanel

    echo -e "${GREEN}[+] Foreign server configured successfully with anti-filter tunnel!${RESET}"
    echo -e "${CYAN}[+] Smart Web Panel installed on port 5000.${RESET}"
    echo -e "    Access it via: http://$IP_FOREIGN:5000"
    echo -e "    Username: jbar  |  Password: jbar"

else
    echo -e "${RED}[!] Invalid selection. Please enter 1, 2 or 3.${RESET}"
    exit 1
fi
