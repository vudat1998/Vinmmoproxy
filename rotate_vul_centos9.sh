#!/bin/bash
#
# rotate_vul_centos9.sh - Xoay (rotate) proxy IPv6 trên CentOS 9 Stream x64
#

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXYCFG="/usr/local/etc/3proxy/3proxy.cfg"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

mkdir -p "$WORKDIR"

# 1) Hàm xóa toàn bộ IPv6 cũ có cùng prefix
clear_old_ipv6() {
    local prefix="$1"
    echo "🔄 Xóa tất cả IPv6 cũ trên interface $IFACE với prefix $prefix..."
    # Lấy danh sách mọi địa chỉ inet6 có prefix, sau đó xóa
    ip -6 addr show dev "$IFACE" | \
      awk -v pfx="$prefix" '$1=="inet6" && $2 ~ "^"pfx {print $2}' | \
      while read -r old; do
          ip -6 addr del "$old" dev "$IFACE"
      done
}

# 2) Hàm sinh chuỗi ngẫu nhiên 5 ký tự
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# 3) Mảng hex để sinh phần suffix IPv6
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# 4) Hàm sinh dữ liệu proxy mới: user/pass, IPv4, port, IPv6
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6")"
    done > "$WORKDATA"
}

# 5) Hàm sinh file cấu hình 3proxy mới dựa trên data.txt
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
users $(awk -F "/" 'BEGIN{ORS="";} {printf "%s:CL:%s ", \$1, \$2}' "${WORKDATA}")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' "${WORKDATA}")
EOF
}

# 6) Hàm ghi file proxy.txt (host:port:user:pass) cho người dùng
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "${WORKDATA}" > "$WORKDIR/proxy.txt"
}

# --- Bắt đầu chạy rotate ---

# A) Lấy prefix IPv6 hiện tại (4 block đầu)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6=$(echo "$IP6_FULL" | cut -f1-4 -d':')
if [[ -z "$IP6" ]]; then
    echo "❌ Không lấy được prefix IPv6."
    exit 1
fi

# B) Xóa IPv6 cũ trên interface
clear_old_ipv6 "$IP6"

# C) Dừng dịch vụ 3proxy (nếu đang chạy)
echo "⏸️ Tạm dừng 3proxy..."
systemctl stop 3proxy || true

# D) Lấy IPv4 và hỏi số lượng proxy
IP4=$(curl -4 -s icanhazip.com)
if [[ -z "$IP4" ]]; then
    echo "❌ Không lấy được IPv4."
    exit 1
fi
echo "🔍 IPv4 hiện tại: $IP4"
echo "🔍 IPv6 prefix: $IP6"
echo "🔍 IPv4 hiện tại: $IP4"
echo "🔍 IPv6 prefix: $IP6"
read -rp "How many proxy do you want to create? " COUNT
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Số lượng không hợp lệ."
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))

# E) Tạo data.txt mới
echo "➡️ Tạo file dữ liệu proxy (data.txt)..."
gen_data

# F) Thêm IPv6 mới lên interface
echo "➡️ Thêm IPv6 mới lên interface $IFACE..."
awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev "iface}' "${WORKDATA}" > "${WORKDIR}/boot_ifconfig.sh"
chmod +x "${WORKDIR}/boot_ifconfig.sh"
bash "${WORKDIR}/boot_ifconfig.sh"

# G) Cập nhật cấu hình 3proxy mới
echo "➡️ Cập nhật cấu hình 3proxy..."
gen_3proxy > "$PROXYCFG"
chmod 644 "$PROXYCFG"

# H) Khởi động lại 3proxy
echo "➡️ Khởi động lại dịch vụ 3proxy..."
ulimit -n 10048
systemctl daemon-reload
systemctl start 3proxy

# I) Ghi file proxy.txt cho user tải xuống
gen_proxy_file_for_user

echo "✅ Rotate proxy hoàn tất!"
echo "- File danh sách proxy: $WORKDIR/proxy.txt"
echo "- Để tự động thêm IPv6 sau reboot, chạy: bash $WORKDIR/boot_ifconfig.sh"
echo "Rotate Done"
