#!/bin/bash
# rotate_vul_centos9.sh
# Xoay proxy IPv6 trên VPS Vultr - CentOS 9
# Nhận $1 là số lượng port cần xoay

set -e

COUNT=${1:-500}  # Default 500 nếu không truyền tham số
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6=$(echo "$IP6_FULL" | cut -f1-4 -d':')

if [ -z "$IP4" ] || [ -z "$IP6" ]; then
    echo "❌ Không lấy được IPv4 hoặc IPv6."
    exit 1
fi

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

echo "==> Gỡ IPv6 cũ..."
bash "${WORKDIR}/boot_ifconfig_delete.sh" || true

echo "==> Sinh lại dữ liệu proxy..."
FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

> "$WORKDATA"
for ((port = FIRST_PORT; port <= LAST_PORT; port++)); do
    echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6")" >> "$WORKDATA"
done

echo "==> Gán lại IPv6 mới..."
cat >"${WORKDIR}/boot_ifconfig.sh" <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr add \$ipv6/64 dev $IFACE
done < "$WORKDATA"
EOF

cat >"${WORKDIR}/boot_ifconfig_delete.sh" <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr del \$ipv6/64 dev $IFACE
done < "$WORKDATA"
EOF

chmod +x "${WORKDIR}/boot_ifconfig.sh" "${WORKDIR}/boot_ifconfig_delete.sh"
bash "${WORKDIR}/boot_ifconfig.sh"

echo "==> Cập nhật 3proxy.cfg..."
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
} > /usr/local/etc/3proxy/3proxy.cfg

chmod 644 /usr/local/etc/3proxy/3proxy.cfg

awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA" > "${WORKDIR}/proxy.txt"

echo "==> Restart 3proxy..."
systemctl restart 3proxy

echo "✅ Rotate proxy thành công!"
