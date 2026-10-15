#!/bin/sh
PLIST=/Library/LaunchDaemons/com.local.batteryd.plist
BIN=/usr/local/bin/batteryd

launchctl bootout system "$PLIST" 2>/dev/null || true
# 服务退出时会自己恢复一次；这里再确认一遍，失败就保留 batteryd 以便重试
if [ -x "$BIN" ] && ! "$BIN" restore; then
    rm -f "$PLIST" /var/run/batteryd.json
    echo "后台服务已停止，但恢复默认充电失败，充电可能仍受限制。" >&2
    echo "请运行 sudo $BIN restore 重试，成功后再卸载一次。" >&2
    exit 1
fi
rm -f "$PLIST" "$BIN" /var/db/batteryd.state /var/db/batteryd.reached /var/run/batteryd.json
rm -rf "/Library/Application Support/batteryd"
echo "已卸载，充电行为已恢复默认"
