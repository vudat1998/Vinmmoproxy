#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

# Ham xoa tat ca proxy hien tai
clear_proxy_and_file() {
    echo "" > /usr/local/etc/3proxy/3proxy.cfg
    echo "" > $WORKDIR/data.txt
    echo "" > $WORKDIR/proxy.txt

    chmod +x "${WORKDIR}/boot_ifconfig_delete.sh"
    bash "${WORKDIR}/boot_ifconfig_delete.sh"

    ps aux | grep '[3]proxy' | awk '{print $2}' | xargs -r kill -9
    systemctl restart NetworkManager

    echo "" > ${WORKDIR}/boot_ifconfig.sh
}

# Ham sinh chuoi ngau nhien
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Sinh dia chi IPv6 ngau nhien tu subnet
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Sinh cau hinh 3proxy
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
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush\n"}' ${WORKDATA})
EOF
}

# Ghi danh sach proxy vao file de nguoi dung su dung
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA} > "$WORKDIR/proxy.txt"
}

# Tao du lieu ngau nhien cho proxy
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# Tao script cau hinh dia chi IPv6
gen_ifconfig() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev " iface}' ${WORKDATA}
}

# Tao script xoa dia chi IPv6
gen_ifconfig_delete() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr del " $5 "/64 dev " iface}' ${WORKDATA}
}

# --- Bat dau thuc thi ---
mkdir -p "$WORKDIR"
clear_proxy_and_file

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP = ${IP4}, IPv6 Prefix = ${IP6}"
echo "How many proxy do you want to create?"
read COUNT

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT - 1))

# Tao du lieu proxy
gen_data > "${WORKDATA}"

# Tao script ifconfig them/xoa
gen_ifconfig > "${WORKDIR}/boot_ifconfig.sh"
gen_ifconfig_delete > "${WORKDIR}/boot_ifconfig_delete.sh"
chmod +x "${WORKDIR}/boot_ifconfig.sh" "${WORKDIR}/boot_ifconfig_delete.sh"

# Tao file cau hinh 3proxy
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# Them IPv6 vao interface
bash "${WORKDIR}/boot_ifconfig.sh"

# Khoi dong lai 3proxy
ulimit -n 10048
systemctl daemon-reload
systemctl restart 3proxy

# Ghi file cho nguoi dung
gen_proxy_file_for_user

echo "✅ Xoay proxy thanh cong!"
echo "- Danh sach proxy: $WORKDIR/proxy.txt"
echo "- Chay lai IPv6 khi reboot: bash ${WORKDIR}/boot_ifconfig.sh"
echo "Rotate Done"
