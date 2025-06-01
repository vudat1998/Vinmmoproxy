#!/bin/bash
#
# rotate_vul_centos9.sh
# Xoay lại proxy trên CentOS 9 Stream x64:
#   • Xóa IPv6 cũ, sinh user/pass mới, port mới, IPv6 mới
#   • Cập nhật 3proxy.cfg, khởi động lại 3proxy
#   • Xuất data.txt và proxy.txt
#

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXYTXT="$WORKDIR/proxy.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

# 1) Tạo thư mục nếu chưa có
mkdir -p "$WORKDIR"

# 2) Lấy IPv6 prefix /64
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':')
if [[ -z "$IP6_PREFIX" ]]; then
    echo "❌ Không lấy được prefix IPv6."
    exit 1
fi

echo "[*] Prefix IPv6: $IP6_PREFIX"
echo "[*] Xóa tất cả IPv6 cũ trên interface $IFACE..."
# Xóa sạch IPv6 cũ
ip -6 addr flush dev "$IFACE" || true

# 3) Dừng 3proxy (nếu đang chạy)
echo "[*] Dừng 3proxy (nếu có)..."
systemctl stop 3proxy || true

# 4) Lấy IPv4
IP4=$(curl -4 -s icanhazip.com)
if [[ -z "$IP4" ]]; then
    echo "❌ Không lấy được IPv4."
    exit 1
fi
echo "[*] IPv4 hiện tại: $IP4"

# 5) Nhận COUNT: nếu truyền $1 (qua Paramiko), dùng luôn; ngược lại hỏi prompt
if [[ -n "$1" && "$1" =~ ^[0-9]+$ ]]; then
    COUNT="$1"
    echo "[*] Sử dụng COUNT từ tham số: $COUNT"
else
    read -rp "How many proxy do you want to create? (e.g., 500) " COUNT
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
        echo "❌ Số lượng không hợp lệ!"
        exit 1
    fi
fi

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))
echo "[*] Khoảng port: $FIRST_PORT đến $LAST_PORT"

# 6) Sinh data.txt mới
echo "[*] Tạo file data.txt..."
> "$WORKDATA"
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
random() { tr -dc A-Za-z0-9 </dev/urandom | head -c5; echo; }
gen64() {
    ip64() { printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$IP6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
}
for port in $(seq "$FIRST_PORT" "$LAST_PORT"); do
    echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64)" >> "$WORKDATA"
done

# 7) Gán IPv6 mới lên interface
echo "[*] Gán IPv6 mới lên interface $IFACE..."
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr add "$ipv6"/64 dev "$IFACE"
done < "$WORKDATA"

# 8) Cập nhật cấu hình 3proxy
echo "[*] Viết lại 3proxy.cfg..."
{
    echo "daemon"
    echo "maxconn 1000"
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"
    echo "setuid 65535"
    echo "flush"
    echo -n "users "
    awk -F "/" '{printf "%s:CL:%s ", $1, $2}' "$WORKDATA"
    echo ""
    echo "auth strong"
    echo "allow *"
    awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' "$WORKDATA"
} > "$CFG3PROXY"
chmod 644 "$CFG3PROXY"

# 9) Khởi động lại 3proxy
echo "[*] Khởi động lại 3proxy..."
ulimit -n 10048
systemctl daemon-reload
systemctl start 3proxy

# 10) Xuất proxy.txt
echo "[*] Tạo proxy.txt..."
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "$PROXYTXT"

# 11) Mở firewall cho dải port (nếu cần)
echo "[*] Mở firewall cho port $FIRST_PORT-$LAST_PORT..."
firewall-cmd --permanent --add-port="${FIRST_PORT}-${LAST_PORT}/tcp" || true
firewall-cmd --reload || true

echo "✅ Rotate proxy thành công!"
echo "- data.txt: $WORKDATA"
echo "- proxy.txt: $PROXYTXT"
echo "Rotate Done"
