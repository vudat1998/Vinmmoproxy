#!/bin/bash
#
# rotate_centos7.sh
# Xoay proxy IPv6 “sạch” trên CentOS 7.9
#

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXYTXT="$WORKDIR/proxy.txt"
CFG3PROXY="/usr/local/etc/3proxy/3proxy.cfg"

# 1) Tìm interface mặc định (IPv4 ưu tiên, nếu không có thì lấy IPv6)
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
[[ -z "$IFACE" ]] && IFACE=$(ip -o -6 route show to default | awk '{print $5; exit}')
[[ -z "$IFACE" ]] && { echo "❌ Không phát hiện được interface."; exit 1; }
echo "[*] Interface: $IFACE"

# 2) Hàm xoá proxy/IPv6/iptables cũ
clear_old() {
  echo "[*] Xoá config 3proxy cũ và data cũ..."
  : > "$CFG3PROXY"
  : > "$WORKDATA"
  : > "$PROXYTXT"

  # Nếu tồn tại script xóa IPv6 cũ thì chạy
  [[ -x "$WORKDIR/boot_ifconfig_delete.sh" ]] && bash "$WORKDIR/boot_ifconfig_delete.sh" 2>/dev/null || true

  # Nếu tồn tại script xóa iptables cũ thì chạy
  [[ -x "$WORKDIR/boot_iptables_delete.sh" ]] && bash "$WORKDIR/boot_iptables_delete.sh" 2>/dev/null || true

  # Dừng 3proxy nếu đang chạy
  pkill -9 3proxy 2>/dev/null || true

  # Restart network để IPv6 cũ được giải phóng
  service network restart 2>/dev/null || true

  # Xoá luôn các boot_*.sh cũ
  > "$WORKDIR/boot_ifconfig.sh"
  > "$WORKDIR/boot_ifconfig_delete.sh"
  > "$WORKDIR/boot_iptables.sh"
  > "$WORKDIR/boot_iptables_delete.sh"
}

# 3) Tạo 5 ký tự ngẫu nhiên
random_str() { tr </dev/urandom -dc A-Za-z0-9 | head -c5; echo; }

# 4) Sinh IPv6 mới dựa trên prefix $1
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
  p="$1"
  r() { printf "%s" "${array[$RANDOM%16]}${array[$RANDOM%16]}${array[$RANDOM%16]}${array[$RANDOM%16]}"; }
  echo "$p:$(r):$(r):$(r):$(r)"
}

# 5) Sinh file cấu hình 3proxy từ data.txt
gen_3proxy() {
  cat <<EOF > "$CFG3PROXY"
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users $(awk -F"/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")
$(awk -F"/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush"}' "$WORKDATA")
EOF
  chmod 644 "$CFG3PROXY"
}

# 6) Sinh proxy.txt cho user tải về
gen_proxy_file() {
  awk -F"/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "$PROXYTXT"
}

# 7) Sinh data.txt (user/pass/IPv4/port/IPv6)
gen_data() {
  seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
    echo "usr$(random_str)/pass$(random_str)/$IP4/$port/$(gen64 "$IP6_PREFIX")"
  done
}

# 8) Sinh script gán IPv6 mới và xóa IPv6 (dùng sau này)
gen_ifconfig_scripts() {
  awk -F"/" -v iface="$IFACE" '{print "ifconfig " iface " inet6 add " $5 "/64"}' "$WORKDATA" > "$WORKDIR/boot_ifconfig.sh"
  awk -F"/" -v iface="$IFACE" '{print "ifconfig " iface " inet6 del " $5 "/64"}' "$WORKDATA" > "$WORKDIR/boot_ifconfig_delete.sh"
  chmod +x "$WORKDIR/boot_ifconfig.sh" "$WORKDIR/boot_ifconfig_delete.sh"
}

# 9) Sinh script thêm/xóa iptables
gen_iptables_scripts() {
  awk -F"/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "$WORKDATA" > "$WORKDIR/boot_iptables.sh"
  awk -F"/" '{print "iptables -D INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "$WORKDATA" > "$WORKDIR/boot_iptables_delete.sh"
  chmod +x "$WORKDIR/boot_iptables.sh" "$WORKDIR/boot_iptables_delete.sh"
}

### === Bắt đầu thực thi ===
mkdir -p "$WORKDIR"

# Xóa toàn bộ cũ
clear_old

# Lấy IPv4 và prefix IPv6 /64
IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6_PREFIX=$(echo "$IP6_FULL" | cut -f1-4 -d':')
if [[ -z "$IP4" || -z "$IP6_PREFIX" ]]; then
  echo "❌ Không lấy được IPv4 hoặc IPv6 Prefix."; exit 1
fi
echo "[*] IPv4: $IP4"
echo "[*] IPv6 Prefix: $IP6_PREFIX"

# Hỏi user nhập COUNT
echo "How many proxy do you want to create?"
read -r COUNT
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "❌ COUNT phải là số."; exit 1
fi
echo "[*] COUNT = $COUNT"

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))
echo "[*] Port từ $FIRST_PORT → $LAST_PORT"

# Sinh data.txt
: > "$WORKDATA"
gen_data >> "$WORKDATA"

# Sinh các script gán/xóa IPv6 + iptables
gen_ifconfig_scripts
gen_iptables_scripts

# Gán IPv6 mới
echo "[*] Gán IPv6 mới..."
bash "$WORKDIR/boot_ifconfig.sh"
sleep 1

# Cập nhật 3proxy.cfg
echo "[*] Cập nhật config 3proxy..."
gen_3proxy

# Thêm iptables cho dải port mới
echo "[*] Thêm iptables..."
bash "$WORKDIR/boot_iptables.sh"

# Khởi động lại 3proxy
echo "[*] Restart 3proxy..."
ulimit -n 10048
service 3proxy restart || systemctl restart 3proxy

pgrep -f 3proxy >/dev/null \
  && echo "✅ 3proxy đã chạy." \
  || { echo "❌ 3proxy không chạy. Kiểm tra log"; exit 1; }

# Tạo proxy.txt cho user tải về
gen_proxy_file

echo "✅ Rotate xong. File proxy: $PROXYTXT"
echo "Rotate Done"

