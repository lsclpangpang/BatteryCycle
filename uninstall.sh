#!/bin/sh
PLIST=/Library/LaunchDaemons/com.local.batteryd.plist

launchctl bootout system "$PLIST" 2>/dev/null || true
/usr/local/bin/batteryd restore 2>/dev/null || true
rm -f "$PLIST" /usr/local/bin/batteryd /var/db/batteryd.state /var/db/batteryd.reached /var/run/batteryd.json
rm -rf "/Library/Application Support/batteryd"
echo "已卸载，充电行为已恢复默认"
