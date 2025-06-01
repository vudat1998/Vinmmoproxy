#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXYTXT="${WORKDIR}/proxy.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

# --- Hàm xoá toàn bộ proxy/IPv6 cũ ---
clear_proxy_and_file() {
    # Xóa nội dung file config 3proxy và data/proxy cũ
    echo "" > /usr/local/etc/3proxy/3proxy.cfg
    echo "" > "$WORKDIR/data.txt"
    echo "" > "$WORKDIR/proxy.txt"

    # Chạy script xóa IPv6 cũ (nếu đã tồn tại)
    if [[ -x "${WORKDIR}/boot_ifconfig_delete.sh" ]]; then
        bash "${WORKDIR}/boot_ifconfig_delete.sh"
    fi

    # Kill 3proxy nếu đang chạy
    pkill -9 3proxy 2>/dev/null || true

    # Restart NetworkManager để IPv6 cũ thực sự được nhả ra
    systemctl restart NetworkManager || true

    # Reset file boot_ifconfig.sh (nếu có)
    echo "" > "${WORKDIR}/boot_ifconfig.sh"
}

# --- Hàm sinh chuỗi ngẫu nhiên 5 ký tự (user/pass) ---
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# --- Hàm sinh 1 địa chỉ IPv6 /64 ngẫu nhiên dựa vào prefix $1 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64_part() {
        printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64_part):$(ip64_part):$(ip64_part):$(ip64_part)"
}

# --- Hàm sinh phần cấu hình 3proxy từ data.txt ---
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
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' "$WORKDATA")
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

# === Bắt đầu chạy chính ===

# 1) Đảm bảo thư mục tồn tại
mkdir -p "$WORKDIR"

# 2) Clear proxy cũ và IPv6 cũ
clear_proxy_and_file

# 3) Lấy IPv4 và prefix IPv6 /64
IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':' )

if [[ -z "$IP4" || -z "$IP6_PREFIX" ]]; then
    echo "❌ Không lấy được IPv4 hoặc IPv6 Prefix."
    exit 1
fi

echo "[*] IPv4 hiện tại: $IP4"
echo "[*] IPv6 Prefix: $IP6_PREFIX"

# 4) Lấy COUNT: nếu truyền $1 phải là số, ngược lại dừng hẳn
if [[ -n "$1" && "$1" =~ ^[0-9]+$ ]]; then
    COUNT="$1"
    echo "[*] Sử dụng COUNT từ tham số: $COUNT"
else
    echo "❌ Bạn bắt buộc phải truyền số lượng proxy làm tham số."
    echo "    Ví dụ: rotate_vul_centos9.sh 500"
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))
echo "[*] Khoảng port: $FIRST_PORT đến $LAST_PORT"

# 5) Sinh data.txt mới
echo "[*] Sinh file data.txt..."
> "$WORKDATA"
gen_data >> "$WORKDATA"

# 6) Sinh script gán/xóa IPv6
gen_ifconfig > "${WORKDIR}/boot_ifconfig.sh"
gen_ifconfig_delete > "${WORKDIR}/boot_ifconfig_delete.sh"
chmod +x "${WORKDIR}/boot_ifconfig.sh" "${WORKDIR}/boot_ifconfig_delete.sh"

# 7) Gán lại toàn bộ IPv6 mới lên interface
echo "[*] Gán IPv6 mới..."
bash "${WORKDIR}/boot_ifconfig.sh"

# 8) Tạo lại file cấu hình 3proxy
echo "[*] Cập nhật file cấu hình 3proxy..."
gen_3proxy > "$CFG3PROXY"
chmod 644 "$CFG3PROXY"

# 9) Khởi động lại 3proxy
echo "[*] Khởi động lại 3proxy..."
ulimit -n 10048
systemctl daemon-reload
systemctl start 3proxy

# 10) Xuất proxy.txt để client tải về
echo "[*] Tạo proxy.txt..."
gen_proxy_file_for_user

# 11) Mở firewall cho dải port (ZONE=public)
echo "[*] Mở firewall cho port $FIRST_PORT–$LAST_PORT..."
firewall-cmd --zone=public --permanent --add-port="${FIRST_PORT}-${LAST_PORT}/tcp" 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

echo "✅ Xoay proxy thành công!"
echo "- Danh sách proxy mới: $PROXYTXT"
echo "- Tham số COUNT đã dùng: $COUNT"
echo "Rotate Done"
