#!/bin/bash
#
# install_centos9.sh
# Script cài đặt 3proxy và cấu hình tạo proxy IPv6 trên CentOS 9 Stream x64
#

set -e

echo "==> Cài đặt dependencies với dnf"
dnf install -y gcc make wget bsdtar zip epel-release

dnf install -y iproute iptables iptables-services firewalld policycoreutils-python-utils curl

if ! systemctl is-active --quiet firewalld; then
    echo "==> Bật và khởi động firewalld"
    systemctl enable firewalld
    systemctl start firewalld
fi

SELINUX_STATUS=$(getenforce)
if [ "$SELINUX_STATUS" == "Enforcing" ]; then
    echo "==> SELinux đang ở Enforcing – chuyển thành Permissive"
    setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi

IFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$IFACE" ]; then
    echo "Lỗi: Không phát hiện được interface mạng IPv4 mặc định."
    exit 1
fi
echo "==> Interface mạng: $IFACE"

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

IP4=$(curl -4 -s icanhazip.com)
IP6_FULL=$(curl -6 -s icanhazip.com)
IP6=$(echo "$IP6_FULL" | cut -f1-4 -d':')

if [ -z "$IP4" ] || [ -z "$IP6" ]; then
    echo "Lỗi: Không lấy được IPv4 hoặc IPv6 từ icanhazip.com"
    exit 1
fi
echo "==> IPv4: $IP4"
echo "==> IPv6 prefix: $IP6"

echo "How many proxy do you want to create? (e.g., 500)"
read -r COUNT

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Số lượng không hợp lệ!"
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

echo "==> Khoảng port: $FIRST_PORT đến $LAST_PORT"

echo "==> Tạo danh sách proxy..."
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6")"
    done
}
gen_data >"$WORKDATA"

echo "==> Mở firewall cho port proxy..."
firewall-cmd --permanent --add-port="${FIRST_PORT}-${LAST_PORT}/tcp" || true
firewall-cmd --reload || true

echo "==> Tạo script thêm/xóa IPv6..."
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

if [ ! -f /usr/local/etc/3proxy/bin/3proxy ]; then
    echo "==> Cài đặt 3proxy v0.9.4"
    THIRD_URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
    wget -qO- "$THIRD_URL" | bsdtar -xvf- >/dev/null
    cd 3proxy-0.9.4
    make -f Makefile.Linux

    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.service /etc/systemd/system/3proxy.service

    sed -i 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
    sed -i 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' /etc/systemd/system/3proxy.service
    sed -i 's|RestartSec=60s|RestartSec=0s|' /etc/systemd/system/3proxy.service

    chmod +x /usr/local/etc/3proxy/bin/3proxy
    cd "$WORKDIR"
else
    echo "✅ 3proxy đã được cài đặt, bỏ qua bước cài đặt."
fi

echo "==> Tạo file cấu hình 3proxy..."
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

echo "==> Xuất file proxy.txt cho user..."
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA" > "${WORKDIR}/proxy.txt"

echo "==> Kích hoạt và khởi động dịch vụ 3proxy"
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "✅ Hoàn tất cài đặt proxy!"
echo "- Danh sách proxy: ${WORKDIR}/proxy.txt"
echo "- Sau khi reboot, chạy lại IPv6: bash ${WORKDIR}/boot_ifconfig.sh"
echo "Install Done"
