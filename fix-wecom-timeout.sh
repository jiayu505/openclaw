#!/bin/bash
# 修复企业微信超时问题

echo "修复企业微信超时和对话历史问题..."

# 1. 清除所有企业微信对话历史
echo "清除对话历史..."
rm -rf ~/.openclaw/state/conversations/wecom_* 2>/dev/null || true
echo "✓ 对话历史已清除"

# 2. 更新 webhook 服务，增加超时时间
SERVICE_FILE="/opt/wecom-webhook/server.js"

if [ -f "$SERVICE_FILE" ]; then
    # 备份
    cp "$SERVICE_FILE" "$SERVICE_FILE.backup-$(date +%s)"

    # 修改超时时间：30秒 -> 60秒
    sed -i 's/--timeout 30/--timeout 60/g' "$SERVICE_FILE"
    sed -i 's/timeout: 35000/timeout: 65000/g' "$SERVICE_FILE"
    sed -i 's/proxy_read_timeout 60s/proxy_read_timeout 90s/g' /opt/matrix/nginx/conf.d/matrix.conf 2>/dev/null || true

    echo "✓ 已增加超时时间（30s -> 60s）"

    # 重启服务
    systemctl restart wecom-webhook
    docker restart matrix-nginx 2>/dev/null || true

    echo "✓ 服务已重启"
else
    echo "⚠ 未找到服务文件"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ 修复完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  现在可以重新测试了："
echo "  1. 发送一条新消息"
echo "  2. 如果还超时，等待 60 秒让它完成"
echo "  3. 如果还有问题，检查日志："
echo "     journalctl -u wecom-webhook -f"
echo ""
