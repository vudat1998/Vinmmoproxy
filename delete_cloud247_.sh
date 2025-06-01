#!/bin/bash

WORKDIR="/home/proxy-installer"

echo "[*] Dừng dịch vụ 3proxy nếu đang chạy..."
systemctl stop 3proxy 2>/dev/null
pkill -f 3proxy 2>/dev/null

echo "[*] Xóa iptables rules và IPv6 cũ..."
[ -f "$WORKDIR/boot_iptables_delete.sh" ] && bash "$WORKDIR/boot_iptables_delete.sh"
[ -f "$WORKDIR/boot_ifconfig_delete.sh" ] && bash "$WORKDIR/boot_ifconfig_delete.sh"

echo "[*] Xóa dữ liệu cũ nhưng giữ lại 3proxy..."
rm -f "$WORKDIR"/{data.txt,proxy.txt}
rm -f "$WORKDIR"/boot_{iptables,iptables_delete,ifconfig,ifconfig_delete}.sh

echo "[*] Cấu hình /usr/local/etc/3proxy/3proxy.cfg được reset."
> /usr/local/etc/3proxy/3proxy.cfg

echo "Delete Done"
