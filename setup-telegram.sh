#!/bin/bash
# Telegram Bot 一键接入 OpenClaw

set -e

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Telegram Bot 接入 OpenClaw                                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# 获取 Bot Token
BOT_TOKEN="$1"

if [ -z "$BOT_TOKEN" ]; then
    echo "请输入 Telegram Bot Token:"
    echo "（格式：123456789:ABCdefGHIjklMNOpqrsTUVwxyz）"
    read -p "Token: " BOT_TOKEN
fi

if [ -z "$BOT_TOKEN" ]; then
    echo "✗ Token 不能为空"
    exit 1
fi

log "Token: ${BOT_TOKEN:0:20}...${BOT_TOKEN: -10}"

step "检查 OpenClaw"

if ! command -v openclaw &>/dev/null; then
    echo "✗ OpenClaw 未安装"
    echo "请先运行: curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-openclaw.sh | sudo bash"
    exit 1
fi

log "OpenClaw $(openclaw --version 2>/dev/null || echo '')"

step "配置 Telegram"

# 创建配置文件
mkdir -p ~/.openclaw/channels
cat > ~/.openclaw/channels/telegram.json << EOF
{
  "enabled": true,
  "token": "$BOT_TOKEN",
  "polling": true,
  "webhook": false
}
EOF

log "配置已保存"

step "测试 Bot"

# 测试 Token 是否有效
echo "测试 Bot Token..."
BOT_INFO=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")

if echo "$BOT_INFO" | grep -q '"ok":true'; then
    BOT_NAME=$(echo "$BOT_INFO" | grep -oP '"username":".*?"' | cut -d'"' -f4)
    log "Bot 验证成功: @$BOT_NAME"
else
    echo "✗ Bot Token 无效或网络错误"
    echo "$BOT_INFO"
    exit 1
fi

step "启动 Telegram 通道"

# 重启 OpenClaw Gateway（如果在运行）
if systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
    systemctl restart openclaw-gateway
    log "OpenClaw Gateway 已重启"
else
    warn "OpenClaw Gateway 未运行，请手动启动："
    echo "    openclaw gateway start"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓✓✓ Telegram Bot 接入完成！ ✓✓✓"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Bot 信息："
echo "  📱 用户名: @$BOT_NAME"
echo "  🔑 Token: ${BOT_TOKEN:0:20}..."
echo ""
echo "  测试："
echo "  1. 打开 Telegram"
echo "  2. 搜索 @$BOT_NAME"
echo "  3. 点击 Start"
echo "  4. 发送消息测试"
echo ""
echo "  查看日志："
echo "  journalctl -u openclaw-gateway -f"
echo ""
echo "  ✅ 企业微信服务不受影响，继续正常运行"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
