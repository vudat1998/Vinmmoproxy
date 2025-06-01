#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"

# Hàm xóa proxy và dữ liệu cũ
clear_proxy_and_file() {
    > /usr/local/etc/3proxy/3proxy.cfg
    > $WORKDIR/data.txt
    > $WORKDIR/proxy.txt

    chmod +x ${WORKDIR}/boot_ifconfig_delete.sh ${WORKDIR}/boot_iptables_delete.sh 2>/dev/null
    bash ${WORKDIR}/boot_ifconfig_delete.sh 2>/dev/null
    bash ${WORKDIR}/boot_iptables_delete.sh 2>/dev/null

    pkill -f 3proxy

    # CentOS 7.9 dùng network thay vì NetworkManager
    systemctl restart network

    > ${WORKDIR}/boot_iptables.sh
    > ${WORKDIR}/boot_ifconfig.sh
}

# Sinh chuỗi ngẫu nhiên
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Sinh IPv6 ngẫu nhiên
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Tạo config 3proxy
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
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})
$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# File proxy trả về cho người dùng
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > $WORKDIR/proxy.txt
}

# Sinh dữ liệu proxy ngẫu nhiên
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# Cấu hình iptables
gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' ${WORKDATA}
}

gen_iptables_delete() {
    awk -F "/" '{print "iptables -D INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' ${WORKDATA}
}

# Cấu hình IPv6
gen_ifconfig() {
    awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA}
}

gen_ifconfig_delete() {
    awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64"}' ${WORKDATA}
}

# Bắt đầu thực thi
mkdir -p "$WORKDIR"
clear_proxy_and_file

# Lấy IP hiện tại
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "[*] IPv4 hiện tại: ${IP4}"
echo "[*] IPv6 Prefix: ${IP6}"

echo "Số lượng proxy cần tạo là bao nhiêu?"
read -r COUNT

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

# Tạo dữ liệu
gen_data > "$WORKDATA"

# Tạo script cấu hình
gen_iptables > "${WORKDIR}/boot_iptables.sh"
gen_iptables_delete > "${WORKDIR}/boot_iptables_delete.sh"
gen_ifconfig > "${WORKDIR}/boot_ifconfig.sh"
gen_ifconfig_delete > "${WORKDIR}/boot_ifconfig_delete.sh"
chmod +x ${WORKDIR}/boot_*.sh

# Ghi file config 3proxy
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# Giới hạn file descriptor nếu cần
ulimit -n 10048

# Thêm rule firewall và địa chỉ IPv6
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh

# Tạo file trả về cho người dùng
gen_proxy_file_for_user

# Restart 3proxy
systemctl daemon-reexec
systemctl restart 3proxy

echo "Rotate Done"
