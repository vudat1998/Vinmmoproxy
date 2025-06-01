#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

mkdir -p "$WORKDIR"

# Hàm sinh chuỗi ngẫu nhiên
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Sinh IPv6 ngẫu nhiên từ prefix
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Xóa tất cả địa chỉ IPv6 đang gán có prefix IP6
clear_old_ipv6() {
    echo "[*] Xóa IPv6 cũ trên interface $IFACE..."
    # Lấy prefix từ biến IP6
    local prefix="$1"
    # Lặp qua các địa chỉ inet6 trên IFACE
    ip -6 addr show dev "$IFACE" | \
      awk -v pfx="$prefix" '$1=="inet6" && $2 ~ "^"pfx {print $2}' | \
      while read -r old; do
          ip -6 addr del "$old" dev "$IFACE"
      done
}

# Sinh dữ liệu proxy mới
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6")"
    done
}

# Sinh cấu hình 3proxy
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
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "${WORKDATA}")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush\n"}' "${WORKDATA}")
EOF
}

# Xuất file proxy.txt cho user
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "${WORKDATA}" > "$WORKDIR/proxy.txt"
}

# Tạo script thêm IPv6 mới
gen_ifconfig_add() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev " iface}' "${WORKDATA}" > "${WORKDIR}/boot_ifconfig.sh"
}

# --- Bắt đầu rotate ---

# 1) Lấy prefix và xóa mọi IPv6 cũ có cùng prefix
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
clear_old_ipv6 "$IP6"

# 2) Dừng 3proxy (nếu đang chạy)
echo "[*] Tạm dừng 3proxy..."
systemctl stop 3proxy || true

# 3) Lấy lại IP4 và prefix, hỏi số lượng proxy
IP4=$(curl -4 -s icanhazip.com)
echo "🔍 IPv4 hiện tại: $IP4"
echo "🔍 IPv6 prefix: $IP6"
echo "How many proxy do you want to create?"
read -r COUNT

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Số không hợp lệ"
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))

# 4) Tạo dữ liệu proxy mới
echo "[*] Tạo dữ liệu proxy..."
gen_data > "${WORKDATA}"

# 5) Gán IPv6 mới
echo "[*] Thêm IPv6 mới lên interface..."
gen_ifconfig_add
chmod +x "${WORKDIR}/boot_ifconfig.sh"
bash "${WORKDIR}/boot_ifconfig.sh"

# 6) Tạo cấu hình 3proxy mới
echo "[*] Cập nhật cấu hình 3proxy..."
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
chmod 644 /usr/local/etc/3proxy/3proxy.cfg

# 7) Khởi động lại 3proxy
echo "[*] Khởi động lại 3proxy..."
ulimit -n 10048
systemctl daemon-reload
systemctl start 3proxy

# 8) Ghi file proxy.txt cho user
gen_proxy_file_for_user

echo "✅ Rotate proxy hoàn tất!"
echo "- Danh sách proxy: $WORKDIR/proxy.txt"
echo "- Để tự động thêm IPv6 sau reboot, chạy: bash $WORKDIR/boot_ifconfig.sh"
echo "Rotate Done"
