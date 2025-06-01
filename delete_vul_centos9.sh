# delete.sh
#!/bin/bash
WORKDIR="/home/proxy-installer"

echo "[*] Dừng dịch vụ 3proxy nếu đang chạy..."
systemctl stop 3proxy 2>/dev/null
pkill -9 3proxy 2>/dev/null

echo "[*] Xóa rules iptables và địa chỉ IPv6..."
if [ -f "$WORKDIR/boot_iptables_delete.sh" ]; then
    bash "$WORKDIR/boot_iptables_delete.sh"
fi
if [ -f "$WORKDIR/boot_ifconfig_delete.sh" ]; then
    bash "$WORKDIR/boot_ifconfig_delete.sh"
fi

echo "[*] Xóa file dữ liệu và script sinh..."
rm -f "$WORKDIR/data.txt" "$WORKDIR/proxy.txt"
rm -f "$WORKDIR"/boot_{iptables,iptables_delete,ifconfig,ifconfig_delete}.sh

echo "[*] Giữ lại 3proxy binary và service file để cài nhanh lần sau."
echo "[*] Delete Done."
