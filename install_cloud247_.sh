#!/bin/bash

check_iptables_install() {
    if ! iptables -V &> /dev/null
    then
        echo "iptables chưa được cài đặt. Đang tiến hành cài đặt..."
        yum install -y iptables-services
        systemctl enable iptables
        systemctl start iptables
    else
        echo "iptables đã được cài đặt."
    fi
}

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

install_3proxy() {
    if [ -f /usr/local/etc/3proxy/bin/3proxy ]; then
        echo "3proxy đã được cài đặt. Bỏ qua bước cài đặt."
        return
    fi
    echo "Đang cài đặt 3proxy..."
    URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
    yum install -y gcc bsdtar make net-tools zip >/dev/null
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.4 || exit
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.service /etc/systemd/system/3proxy.service
    sed -i 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
    sed -i 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' /etc/systemd/system/3proxy.service
    sed -i 's/RestartSec=60s/RestartSec=0s/' /etc/systemd/system/3proxy.service
    chmod +x /usr/local/etc/3proxy/bin/3proxy
    systemctl daemon-reload
    systemctl enable 3proxy
    cd ..
    rm -rf 3proxy-0.9.4
}

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

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' ${WORKDATA}
}

gen_iptables_delete() {
    awk -F "/" '{print "iptables -D INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' ${WORKDATA}
}

gen_ifconfig() {
    awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA}
}

gen_ifconfig_delete() {
    awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64"}' ${WORKDATA}
}

echo "Bắt đầu cài đặt các ứng dụng cần thiết..."
yum install -y gcc net-tools bsdtar zip curl >/dev/null
check_iptables_install
install_3proxy

echo "Thiết lập thư mục làm việc /home/proxy-installer"
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR || exit

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP = ${IP4}. External IPv6 prefix = ${IP6}"

echo "How many proxy do you want to create?"
read -r COUNT

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

gen_data > $WORKDATA

gen_iptables_delete > $WORKDIR/boot_iptables_delete.sh
gen_iptables > $WORKDIR/boot_iptables.sh

gen_ifconfig_delete > $WORKDIR/boot_ifconfig_delete.sh
gen_ifconfig > $WORKDIR/boot_ifconfig.sh

chmod +x $WORKDIR/boot_*.sh

gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
chmod +x /usr/local/etc/3proxy/3proxy.cfg

bash $WORKDIR/boot_iptables.sh
bash $WORKDIR/boot_ifconfig.sh

ulimit -n 10048

gen_proxy_file_for_user

systemctl daemon-reload
systemctl restart 3proxy

echo "Install Done"
