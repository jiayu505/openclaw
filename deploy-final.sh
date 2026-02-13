#!/bin/bash
# 部署最终版本
set -e

echo "部署 WeCom × OpenClaw 最终版本..."

systemctl stop wecom-webhook

cd /opt/wecom-webhook

# 下载最终版本
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/wecom-final.js -o server.js

echo "✓ 代码已更新"

systemctl start wecom-webhook

echo "✓ 服务已启动"
echo ""
echo "监控日志（发消息测试）："
echo ""

sleep 2
journalctl -u wecom-webhook -f
