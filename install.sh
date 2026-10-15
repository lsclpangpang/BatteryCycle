#!/bin/sh
set -e
cd "$(dirname "$0")"
PLIST=/Library/LaunchDaemons/com.local.batteryd.plist
CONF_DIR="/Library/Application Support/batteryd"

launchctl bootout system "$PLIST" 2>/dev/null || true
# 等旧服务完全退出，否则紧接着 bootstrap 可能报 5: Input/output error
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print system/com.local.batteryd >/dev/null 2>&1 || break
    sleep 0.5
done

# 配置目录允许 admin 组写入，菜单栏 App 以当前用户身份修改设置
mkdir -p "$CONF_DIR"
chown root:admin "$CONF_DIR"
chmod 775 "$CONF_DIR"
[ -f "$CONF_DIR/config" ] || printf 'enabled=1\nlow=10\nhigh=75\n' > "$CONF_DIR/config"
chown root:admin "$CONF_DIR/config"
chmod 664 "$CONF_DIR/config"

mkdir -p /usr/local/bin
install -m 755 -o root -g wheel batteryd /usr/local/bin/batteryd
install -m 644 -o root -g wheel com.local.batteryd.plist "$PLIST"
launchctl bootstrap system "$PLIST"
echo "后台服务已安装并启动。日志: tail -f /var/log/batteryd.log"
