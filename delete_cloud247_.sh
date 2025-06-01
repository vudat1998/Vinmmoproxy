#!/bin/bash

echo "[*] Dừng dịch vụ 3proxy nếu đang chạy..."
systemctl stop 3proxy 2>/dev/null
pkill -f 3proxy 2>/dev/null

echo "[*] Xóa các rules iptables nếu có..."
if [ -f /home/proxy-installer/boot_iptables_delete.sh ]; then
    bash /home/proxy-installer/boot_iptables_delete.sh
fi

echo "[*] Xóa các địa chỉ IPv6 đã gán nếu có..."
if [ -f /home/proxy-installer/boot_ifconfig_delete.sh ]; then
    bash /home/proxy-installer/boot_ifconfig_delete.sh
fi

echo "[*] Xóa dữ liệu proxy và cấu hình 3proxy..."
> /usr/local/etc/3proxy/3proxy.cfg
rm -rf /home/proxy-installer

echo "[*] Đã xóa cấu hình proxy, iptables và địa chỉ IPv6, giữ nguyên 3proxy."

echo "Delete Done"
