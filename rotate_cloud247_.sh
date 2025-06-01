#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXYTXT="${WORKDIR}/proxy.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

# --- Hàm kiểm tra và cài đặt gói cần thiết ---
check_requirements() {
    echo "[*] Kiểm tra các gói cần thiết..."
    yum install -y net-tools curl iproute >/dev/null 2>&1
}

# --- Hàm xoá toàn bộ proxy/IPv6 cũ ---
clear_proxy_and_file() {
    echo "[*] Xoá cấu hình và proxy cũ..."
    > "$CFG3PROXY"
    > "$WORKDATA"
    > "$PROXYTXT"

    if [[ -x "${WORKDIR}/boot_ifconfig_delete.sh" ]]; then
        bash "${WORKDIR}/boot_ifconfig_delete.sh" || echo "[!] Không thể xóa IPv6 cũ."
    fi

    pkill -9 3proxy 2>/dev/null || true

    # Làm mới interface mạng thay vì restart toàn bộ network
    ip link set "$IFACE" down
    sleep 1
    ip link set "$IFACE" up
}

# --- Sinh chuỗi ngẫu nhiên ---
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# --- Sinh 1 địa chỉ IPv6 /64 ngẫu nhiên dựa vào prefix $1 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64_part() {
        printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64_part):$(ip64_part):$(ip64_part):$(ip64_part)"
}

# --- Sinh phần cấu hình 3proxy từ data.txt ---
gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush"}' "$WORKDATA")
EOF
}

# --- Ghi file proxy.txt để người dùng tải về ---
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA" > "$PROXYTXT"
}

# --- Sinh data.txt (user/pass/IPv4/port/IPv6) ---
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6_PREFIX")"
    done
}

# --- Sinh script gán IPv6 lên interface ---
gen_ifconfig() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev " iface}' "$WORKDATA"
}

# --- Sinh script xoá IPv6 khỏi interface ---
gen_ifconfig_delete() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr del " $5 "/64 dev " iface}' "$WORKDATA"
}

# --- Kiểm tra firewall ---
check_firewall() {
    echo "[*] Mở các cổng trong iptables..."
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        iptables -D INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT
    done
    service iptables save 2>/dev/null || true
}

# === Bắt đầu ===
check_requirements
mkdir -p "$WORKDIR"
clear_proxy_and_file

# Lấy IPv4 và prefix IPv6 /64
IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':')

if [[ -z "$IP4" || -z "$IP6_PREFIX" ]]; then
    echo "❌ Không lấy được IPv4 hoặc IPv6 Prefix."
    exit 1
fi

echo "[*] IPv4 hiện tại: $IP4"
echo "[*] IPv6 Prefix: $IP6_PREFIX"

# Nhập COUNT từ người dùng
echo "How many proxy do you want to create?"
read -r COUNT
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ COUNT phải là số nguyên."
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))
echo "[*] Phạm vi port: $FIRST_PORT đến $LAST_PORT"

# Sinh data.txt mới
echo "[*] Tạo data.txt mới..."
> "$WORKDATA"
gen_data >> "$WORKDATA"

# Sinh script gán/xóa IPv6
gen_ifconfig > "$WORKDIR/boot_ifconfig.sh"
gen_ifconfig_delete > "$WORKDIR/boot_ifconfig_delete.sh"
chmod +x "$WORKDIR/boot_ifconfig.sh" "$WORKDIR/boot_ifconfig_delete.sh"

# Gán lại toàn bộ IPv6 mới lên interface
echo "[*] Gán IPv6 mới lên $IFACE..."
bash "$WORKDIR/boot_ifconfig.sh"
sleep 1

# Cập nhật firewall
check_firewall

# Tạo lại file cấu hình 3proxy
echo "[*] Cập nhật file cấu hình 3proxy..."
gen_3proxy > "$CFG3PROXY"
chmod 644 "$CFG3PROXY"

# Restart 3proxy
echo "[*] Khởi động lại 3proxy..."
ulimit -n 10048
systemctl restart 3proxy

if pgrep -f 3proxy >/dev/null; then
    echo "✅ 3proxy đã chạy."
else
    echo "❌ 3proxy không chạy. Kiểm tra log với: journalctl -u 3proxy --no-pager | tail -n 20"
    exit 1
fi

# Xuất proxy.txt để user tải về
echo "[*] Tạo proxy.txt..."
gen_proxy_file_for_user

echo "✅ Xoay proxy thành công!"
echo "- File proxy: $PROXYTXT"
echo "Rotate Done"
