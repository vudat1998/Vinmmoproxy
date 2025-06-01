#!/bin/bash
#
# rotate_vul_centos9.sh
# Xoay proxy IPv6 (và user/pass) mới trên CentOS 9 Stream x64
#

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"
PROXYTXT="${WORKDIR}/proxy.txt"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

mkdir -p "$WORKDIR"

# --- 1) Lấy prefix IPv6 và xóa toàn bộ IPv6 cũ trên interface ---
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':')
if [[ -z "$IP6_PREFIX" ]]; then
    echo "❌ Không lấy được prefix IPv6."
    exit 1
fi

echo "[*] Prefix IPv6: $IP6_PREFIX"
echo "[*] Xóa tất cả địa chỉ IPv6 cũ trên interface $IFACE..."
ip -6 addr show dev "$IFACE" | \
  awk -v pfx="$IP6_PREFIX" '$1=="inet6" && $2 ~ "^"pfx {print $2}' | \
  while read -r old; do
      ip -6 addr del "$old" dev "$IFACE"
  done

# --- 2) Dừng 3proxy (nếu đang chạy) để tránh xung đột khi update config ---
echo "[*] Dừng 3proxy (nếu đang chạy)..."
systemctl stop 3proxy || true

# --- 3) Lấy IPv4 và hỏi số lượng proxy cần tạo ---
IP4=$(curl -4 -s icanhazip.com)
if [[ -z "$IP4" ]]; then
    echo "❌ Không lấy được IPv4."
    exit 1
fi

echo "🔍 IPv4 hiện tại: $IP4"
echo "🔍 IPv6 prefix: $IP6_PREFIX"
read -rp "How many proxy do you want to create? " COUNT
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Số lượng không hợp lệ."
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))

# --- 4) Sinh data.txt mới (user/pass/IPv4/port/IPv6) ---
echo "[*] Tạo file data.txt mới tại $WORKDATA..."
{
    array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    random() { tr </dev/urandom -dc A-Za-z0-9 | head -c5; echo; }
    gen64() {
        ip64() { printf "%s" "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
        echo "$IP6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
    }

    for port in $(seq "$FIRST_PORT" "$LAST_PORT"); do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64)"
    done
} > "$WORKDATA"

# --- 5) Gán IPv6 mới lên interface ---
echo "[*] Gán IPv6 mới lên interface $IFACE..."
awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev " iface}' "$WORKDATA" > "${WORKDIR}/boot_ifconfig.sh"
chmod +x "${WORKDIR}/boot_ifconfig.sh"
bash "${WORKDIR}/boot_ifconfig.sh"

# --- 6) Cập nhật file cấu hình 3proxy ---
echo "[*] Cập nhật cấu hình 3proxy tại $CFG3PROXY..."
{
    echo "daemon"
    echo "maxconn 1000"
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"
    echo "setuid 65535"
    echo "flush"
    echo "auth strong"
    printf "users "
    awk -F "/" '{printf "%s:CL:%s ", $1, $2}' "$WORKDATA"
    echo
    awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush"}' "$WORKDATA"
} > "$CFG3PROXY"
chmod 644 "$CFG3PROXY"

# --- 7) Khởi động lại 3proxy ---
echo "[*] Khởi động lại dịch vụ 3proxy..."
ulimit -n 10048
systemctl daemon-reload
systemctl start 3proxy

# --- 8) Xuất proxy.txt để Python tải xuống ---
echo "[*] Xuất file proxy.txt tại $PROXYTXT..."
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA" > "$PROXYTXT"

echo "✅ Rotate proxy thành công!"
echo "- data.txt: $WORKDATA"
echo "- proxy.txt: $PROXYTXT"
echo "- Nếu reboot VPS, bạn có thể chạy tiếp: bash $WORKDIR/boot_ifconfig.sh"
echo "Rotate Done"
