#!/bin/bash
# 检查 webhook 服务日志

echo "1. 检查 webhook 服务状态..."
systemctl status wecom-webhook --no-pager | head -20

echo ""
echo "2. 检查最近的 webhook 日志（最近 50 行）..."
journalctl -u wecom-webhook -n 50 --no-pager

echo ""
echo "3. 检查是否收到群聊消息..."
journalctl -u wecom-webhook --since "10 minutes ago" | grep -i "received\|message\|群\|group" || echo "没有找到群聊相关日志"

echo ""
echo "4. 测试 webhook 是否可访问..."
curl -v https://tslcz.com/webhooks/wecom 2>&1 | head -20
