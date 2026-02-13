#!/bin/bash
# 查找 OpenClaw 配置

echo "查找 OpenClaw 配置..."

echo ""
echo "1. 检查常见配置位置..."
for path in ~/.openclaw/config.json ~/.config/openclaw/config.json /etc/openclaw/config.json /opt/openclaw/config.json; do
    if [ -f "$path" ]; then
        echo "✓ 找到: $path"
    else
        echo "✗ 不存在: $path"
    fi
done

echo ""
echo "2. 搜索所有 openclaw 相关文件..."
find ~ -name "*openclaw*" -type f 2>/dev/null | head -20

echo ""
echo "3. 检查 OpenClaw 配置命令..."
openclaw config show 2>/dev/null || echo "config show 命令不可用"

echo ""
echo "4. 检查 API Keys..."
openclaw config list-keys 2>/dev/null || echo "list-keys 命令不可用"

echo ""
echo "5. 查看环境变量..."
env | grep -i "anthropic\|claude\|openai" || echo "未找到 AI API 相关环境变量"

echo ""
echo "6. 检查 OpenClaw 安装位置..."
which openclaw
ls -la $(which openclaw)
