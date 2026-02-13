#!/bin/bash
# 更新到 OpenClaw 完整集成版本
set -e

echo "正在更新到 OpenClaw 完整集成版本..."

cd /opt/wecom-webhook

# 备份当前版本
cp server.js server.js.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# 下载完整版本
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/wecom-openclaw-full.js -o server.js

echo "✓ 代码已更新"

# 检测 OpenClaw 路径并更新 .env
OPENCLAW_BIN=$(find /root /home -name "openclaw" -type f -executable 2>/dev/null | grep bin | head -1)
if [ -n "$OPENCLAW_BIN" ]; then
    echo "✓ 检测到 OpenClaw: $OPENCLAW_BIN"
    echo "OPENCLAW_PATH=$OPENCLAW_BIN" >> .env
else
    echo "⚠ 未检测到 OpenClaw，将使用默认路径"
fi

# 重启服务
systemctl restart wecom-webhook

echo "✓ 服务已重启"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw AI 集成已启用！                                     ║"
echo "║  现在发消息测试，将由 OpenClaw AI 智能回复                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "监控日志："
echo ""

sleep 2
journalctl -u wecom-webhook -f
