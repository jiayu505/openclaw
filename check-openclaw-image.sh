#!/bin/bash
# 检查 OpenClaw 是否支持图片

echo "检查 OpenClaw 图片支持..."

echo ""
echo "1. 查看 agent 命令帮助..."
openclaw agent --help | grep -i "image\|picture\|photo" || echo "未找到图片相关参数"

echo ""
echo "2. 查看完整帮助..."
openclaw --help | grep -i "image\|vision\|multimodal" || echo "未找到图片相关功能"

echo ""
echo "3. 检查版本..."
openclaw --version

echo ""
echo "4. 测试是否支持图片 URL..."
openclaw agent --message "描述这张图片" --image "https://picsum.photos/200" --json 2>&1 || echo "不支持 --image 参数"
