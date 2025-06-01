#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXYTXT="${WORKDIR}/proxy.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

# --- Hàm xoá toàn bộ proxy/IPv6 cũ ---
clear_proxy_and_file() {
    echo "[*] Xoá cấu hình và proxy cũ..."
    echo "" > "$CFG3PROXY"
    echo "" > "$WORKDATA"
    echo "" > "$PROXYTXT"

    if [[ -x "${WORKDIR}/boot_ifconfig_delete.sh" ]]; then
        bash "${WORKDIR}/boot_ifconfig_delete.sh"
    fi

    pkill -9 3proxy 2>/dev/null || true
    systemctl restart network || true
    echo "" > "${WORKDIR}/boot_ifconfig.sh"
    echo "" > "${WORKDIR}/boot_iptables.sh"
}

# --- Sinh chuỗi ngẫu nhiên ---
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5; echo
}

# --- Sinh IPv6 ngẫu nhiên ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64_part() {
        printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64_part):$(ip64_part):$(ip64_part):$(ip64_part)"
}

# --- Tạo cấu hình 3proxy ---
gen_3proxy() {
    cat <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users \
$(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush\n"}' "$WORKDATA")
EOF
}

# --- Ghi file proxy.txt ---
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA" > "$PROXYTXT"
}

# --- Sinh data.txt ---
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6_PREFIX")"
    done
}

# --- Sinh script gán IPv6 ---
gen_ifconfig() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev " iface}' "$WORKDATA"
}

# --- Sinh script xoá IPv6 ---
gen_ifconfig_delete() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr del " $5 "/64 dev " iface}' "$WORKDATA"
}

# --- Sinh script iptables mở port ---
gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "$WORKDATA"
}

# === Bắt đầu ===

mkdir -p "$WORKDIR"
clear_proxy_and_file

IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':' )

if [[ -z "$IP4" || -z "$IP6_PREFIX" ]]; then
    echo "❌ Không lấy được IPv4 hoặc IPv6 Prefix."
    exit 1
fi

echo "[*] IPv4: $IP4"
echo "[*] IPv6 Prefix: $IP6_PREFIX"

echo "How many proxy do you want to create?"
read -r COUNT


FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))
echo "[*] Port từ $FIRST_PORT đến $LAST_PORT"

echo "[*] Tạo data.txt..."
> "$WORKDATA"
gen_data >> "$WORKDATA"

echo "[*] Sinh script cấu hình IPv6 và iptables..."
gen_ifconfig > "$WORKDIR/boot_ifconfig.sh"
gen_ifconfig_delete > "$WORKDIR/boot_ifconfig_delete.sh"
gen_iptables > "$WORKDIR/boot_iptables.sh"
chmod +x "$WORKDIR/boot_ifconfig.sh" "$WORKDIR/boot_ifconfig_delete.sh" "$WORKDIR/boot_iptables.sh"

echo "[*] Gán IPv6 mới lên interface..."
bash "$WORKDIR/boot_ifconfig.sh"

echo "[*] Mở port bằng iptables..."
bash "$WORKDIR/boot_iptables.sh"

sleep 2

echo "[*] Ghi cấu hình 3proxy..."
gen_3proxy > "$CFG3PROXY"
chmod 644 "$CFG3PROXY"

echo "[*] Khởi động lại 3proxy..."
ulimit -n 10048
systemctl daemon-reexec
systemctl restart 3proxy

if pgrep -f 3proxy >/dev/null; then
    echo "✅ 3proxy đã khởi động thành công."
else
    echo "❌ 3proxy không chạy. Kiểm tra log với: journalctl -u 3proxy --no-pager | tail -n 30"
    exit 1
fi

echo "[*] Xuất file proxy.txt..."
gen_proxy_file_for_user

echo "✅ Hoàn tất xoay proxy. File: $PROXYTXT"
echo "Rotate Done"
