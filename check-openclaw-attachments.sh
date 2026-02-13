#!/bin/bash
# 检查 OpenClaw 如何处理附件/文件

echo "检查 OpenClaw 附件/文件支持..."

echo ""
echo "1. 查看 agent 命令的所有参数..."
openclaw agent --help

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "2. 搜索文件相关参数..."
openclaw agent --help | grep -i "file\|attach\|path\|upload" || echo "未找到文件相关参数"

echo ""
echo "3. 测试可能的参数..."
echo "   尝试 --file:"
openclaw agent --message "测试" --file "/tmp/test.txt" 2>&1 | head -5 || true

echo ""
echo "   尝试 --attachment:"
openclaw agent --message "测试" --attachment "/tmp/test.txt" 2>&1 | head -5 || true

echo ""
echo "   尝试 --files:"
openclaw agent --message "测试" --files "/tmp/test.txt" 2>&1 | head -5 || true

echo ""
echo "4. 查看 Telegram 插件配置（看它怎么处理图片）..."
find ~/.openclaw -name "*telegram*" -o -name "*tg*" 2>/dev/null | head -5

echo ""
echo "5. 检查 OpenClaw 插件列表..."
openclaw plugin list 2>/dev/null || echo "未找到 plugin 命令"
