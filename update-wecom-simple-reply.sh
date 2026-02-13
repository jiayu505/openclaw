#!/bin/bash
# 更新 WeCom Webhook 服务为简单回复版本（测试用）
set -e

echo "正在更新 WeCom Webhook 服务..."

cd /opt/wecom-webhook

# 备份当前版本
cp server.js server.js.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# 下载新版本（简单回复，不调用 OpenClaw）
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/wecom-simple-reply.js -o server.js

echo "✓ 代码已更新"

# 重启服务
systemctl restart wecom-webhook

echo "✓ 服务已重启"
echo ""
echo "现在监控日志（发消息测试）："
echo ""

sleep 2
journalctl -u wecom-webhook -f
