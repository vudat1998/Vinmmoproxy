#!/bin/bash
#
# rotate_centos7.sh
#
# Script “xoay” proxy IPv6 (3proxy) trên CentOS 7.9
# – Tự động phát hiện interface mạng (IPv4/IPv6)
# – Xóa các thiết lập cũ (iptables + IPv6)
# – Sinh user/pass + IPv6 mới
# – Gán IPv6 mới lên interface vừa phát hiện
# – Tạo lại rule iptables cho dải port
# – Cập nhật cấu hình 3proxy và khởi động lại
# – Xuất proxy.txt để tải về
#

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXYTXT="${WORKDIR}/proxy.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"

# --- 1) Tự động phát hiện interface mạng IPv4/IPv6 mặc định ---
# Lấy interface đi ra internet bằng IPv4
IFACE4=$(ip -o -4 route show to default | awk '{print $5; exit}')
# Lấy interface đi ra internet bằng IPv6 (nếu có)
IFACE6=$(ip -o -6 route show to default | awk '{print $5; exit}')

# Nếu chỉ có IPv4, dùng IFACE4; nếu chỉ có IPv6, dùng IFACE6; nếu cả 2, ưu tiên IFACE4
if [[ -n "$IFACE4" ]]; then
    IFACE="$IFACE4"
elif [[ -n "$IFACE6" ]]; then
    IFACE="$IFACE6"
else
    echo "❌ Không phát hiện được interface mạng mặc định."
    exit 1
fi

echo "[*] Interface đã phát hiện: $IFACE"

# --- 2) Hàm xóa toàn bộ proxy/IPv6/iptables cũ ---
clear_proxy_and_file() {
    echo "[*] Xóa cấu hình và dữ liệu cũ..."

    # Xóa nội dung file cấu hình 3proxy và các file data/proxy cũ
    : > "$CFG3PROXY"
    : > "$WORKDATA"
    : > "$PROXYTXT"

    # Nếu script xóa IPv6 cũ tồn tại, chạy
    if [[ -x "$WORKDIR/boot_ifconfig_delete.sh" ]]; then
        bash "$WORKDIR/boot_ifconfig_delete.sh"
    fi

    # Nếu script xóa iptables cũ tồn tại, chạy
    if [[ -x "$WORKDIR/boot_iptables_delete.sh" ]]; then
        bash "$WORKDIR/boot_iptables_delete.sh"
    fi

    # Dừng tất cả tiến trình 3proxy cũ
    pkill -9 3proxy 2>/dev/null || true

    # Khởi động lại network để đảm bảo IPv6 cũ được nhả ra
    service network restart 2>/dev/null || true

    # Reset nội dung 2 script gán/xóa IPv6 và iptables
    : > "$WORKDIR/boot_ifconfig.sh"
    : > "$WORKDIR/boot_iptables.sh"
}

# --- 3) Sinh chuỗi ngẫu nhiên 5 ký tự (dùng làm user/pass) ---
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# --- 4) Sinh 1 địa chỉ IPv6 /64 mới dựa vào prefix $1 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64_part() {
        printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64_part):$(ip64_part):$(ip64_part):$(ip64_part)"
}

# --- 5) Tạo file cấu hình 3proxy từ data.txt ---
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
users $(awk -F"/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")
$(awk -F"/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush\n"}' "$WORKDATA")
EOF
}

# --- 6) Tạo file proxy.txt cho client tải về ---
gen_proxy_file_for_user() {
    awk -F"/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "$PROXYTXT"
}

# --- 7) Sinh dữ liệu data.txt (user/pass/IPv4/port/IPv6) ---
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6_PREFIX")"
    done
}

# --- 8) Tạo script gán IPv6 mới lên interface ---
gen_ifconfig() {
    awk -F"/" -v iface="$IFACE" '{print "ifconfig " iface " inet6 add " $5 "/64"}' "$WORKDATA"
}

# --- 9) Tạo script xóa IPv6 cũ ---
gen_ifconfig_delete() {
    awk -F"/" -v iface="$IFACE" '{print "ifconfig " iface " inet6 del " $5 "/64"}' "$WORKDATA"
}

# --- 10) Tạo script thêm rule iptables cho dải port mới ---
gen_iptables() {
    awk -F"/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "$WORKDATA"
}

# --- 11) Tạo script xóa rule iptables cũ ---
gen_iptables_delete() {
    awk -F"/" '{print "iptables -D INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "$WORKDATA"
}

# === Bắt đầu chạy chính ===

mkdir -p "$WORKDIR"

# 1) Xóa proxy / IPv6 / iptables cũ (nếu tồn tại)
clear_proxy_and_file

# 2) Lấy địa chỉ IP hiện tại (IPv4 + prefix IPv6 /64)
IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':')

if [[ -z "$IP4" || -z "$IP6_PREFIX" ]]; then
    echo "❌ Không lấy được IPv4 hoặc IPv6 Prefix."
    exit 1
fi

echo "[*] IPv4 hiện tại  : $IP4"
echo "[*] IPv6 Prefix    : $IP6_PREFIX"

# 3) Hỏi người dùng nhập số lượng proxy cần tạo
echo "How many proxy do you want to create?"
read -r COUNT

# Xác nhận COUNT là số nguyên dương
if [[ -z "$COUNT" || ! "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Số lượng không hợp lệ (phải là số nguyên dương)."
    exit 1
fi

echo "[*] Số lượng proxy : $COUNT"

# 4) Xác định dải port (từ 10000 đến 10000+COUNT-1)
FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))
echo "[*] Khoảng port    : $FIRST_PORT → $LAST_PORT"

# 5) Sinh dữ liệu mới vào data.txt
echo "[*] Sinh file data.txt..."
: > "$WORKDATA"
gen_data >> "$WORKDATA"

# 6) Sinh script gán/xóa IPv6
echo "[*] Tạo script gán/xóa IPv6..."
gen_ifconfig > "$WORKDIR/boot_ifconfig.sh"
gen_ifconfig_delete > "$WORKDIR/boot_ifconfig_delete.sh"
chmod +x "$WORKDIR/boot_ifconfig.sh" "$WORKDIR/boot_ifconfig_delete.sh"

# 7) Sinh script xóa và thêm iptables
echo "[*] Tạo script iptables..."
gen_iptables > "$WORKDIR/boot_iptables.sh"
gen_iptables_delete > "$WORKDIR/boot_iptables_delete.sh"
chmod +x "$WORKDIR/boot_iptables.sh" "$WORKDIR/boot_iptables_delete.sh"

# 8) Gán toàn bộ IPv6 mới lên interface
echo "[*] Gán IPv6 mới lên interface $IFACE..."
bash "$WORKDIR/boot_ifconfig.sh"
sleep 1

# 9) Cập nhật lại file cấu hình 3proxy
echo "[*] Cập nhật cấu hình 3proxy..."
gen_3proxy > "$CFG3PROXY"
chmod 644 "$CFG3PROXY"

# 10) Thêm rule iptables cho dải port mới
echo "[*] Thêm rule iptables cho port $FIRST_PORT–$LAST_PORT..."
bash "$WORKDIR/boot_iptables.sh"

# 11) Khởi động lại dịch vụ 3proxy
echo "[*] Khởi động lại 3proxy..."
ulimit -n 10048
service 3proxy restart 2>/dev/null || systemctl restart 3proxy

if pgrep -f 3proxy >/dev/null; then
    echo "✅ 3proxy đã khởi động thành công."
else
    echo "❌ Lỗi: 3proxy không chạy. Kiểm tra log:"
    journalctl -u 3proxy --no-pager | tail -n 20
    exit 1
fi

# 12) Xuất file proxy.txt để client tải về
echo "[*] Tạo file proxy.txt..."
gen_proxy_file_for_user

echo "✅ Đã xoay proxy thành công!"
echo "- Danh sách proxy mới: $PROXYTXT"
echo "- Nếu bạn dùng firewalld, hãy mở dải port:"
echo "    firewall-cmd --zone=public --permanent --add-port=${FIRST_PORT}-${LAST_PORT}/tcp"
echo "    firewall-cmd --reload"

echo "Rotate Done"
