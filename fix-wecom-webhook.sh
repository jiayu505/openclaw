#!/bin/bash
###############################################################################
# OpenClaw WeCom Webhook 自动诊断修复脚本
# 用法: curl -fsSL <URL> | sudo bash
###############################################################################
set -e

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
step() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

step "诊断 WeCom 配置"

# 1. 检查 gateway 状态
if ! openclaw status &>/dev/null; then
    err "OpenClaw Gateway 未运行"
    exit 1
fi
log "Gateway 运行正常"

# 2. 检查 WeCom 插件
PLUGIN_STATUS=$(openclaw plugins list 2>&1 | grep wecom || echo "")
if [[ -z "$PLUGIN_STATUS" ]]; then
    err "WeCom 插件未安装"
    echo "请先运行: openclaw plugins install @sunnoy/wecom"
    exit 1
fi
log "WeCom 插件已安装"

# 3. 检查配置
WECOM_CONFIG=$(openclaw config get channels.wecom 2>/dev/null || echo "{}")
if echo "$WECOM_CONFIG" | grep -q '"enabled": true'; then
    log "WeCom 渠道已启用"
else
    warn "WeCom 渠道未启用，正在启用..."
    openclaw config set channels.wecom.enabled true
fi

# 4. 检查必要字段
CORP_ID=$(echo "$WECOM_CONFIG" | grep -oP '"corpId":\s*"\K[^"]+' || echo "")
AGENT_ID=$(echo "$WECOM_CONFIG" | grep -oP '"agentId":\s*\K[0-9]+' || echo "")
TOKEN=$(echo "$WECOM_CONFIG" | grep -oP '"token":\s*"\K[^"]+' || echo "")
AES_KEY=$(echo "$WECOM_CONFIG" | grep -oP '"encodingAesKey":\s*"\K[^"]+' || echo "")

if [[ -z "$CORP_ID" ]] || [[ -z "$AGENT_ID" ]] || [[ -z "$TOKEN" ]] || [[ -z "$AES_KEY" ]]; then
    err "WeCom 配置不完整"
    echo "corpId: $CORP_ID"
    echo "agentId: $AGENT_ID"
    echo "token: $TOKEN"
    echo "encodingAesKey: ${AES_KEY:0:10}..."
    exit 1
fi
log "WeCom 配置完整"

step "强制重新初始化 WeCom 渠道"

# 禁用 → 启用 → 重启（触发重新注册 webhook targets）
openclaw config set channels.wecom.enabled false >/dev/null 2>&1
sleep 1
openclaw config set channels.wecom.enabled true >/dev/null 2>&1
log "渠道已重新启用"

# 重启 gateway
openclaw gateway restart >/dev/null 2>&1 &
RESTART_PID=$!
echo -n "等待 gateway 重启"
for i in {1..10}; do
    echo -n "."
    sleep 1
done
echo ""
wait $RESTART_PID 2>/dev/null || true
log "Gateway 已重启"

step "测试 Webhook"

# 等待服务完全启动
sleep 3

# 测试 webhook 响应
echo "测试: curl https://tslcz.com/webhooks/wecom?echostr=test"
RESPONSE=$(curl -s "https://tslcz.com/webhooks/wecom?echostr=test&timestamp=123&nonce=456&msg_signature=test" 2>&1)

if echo "$RESPONSE" | grep -qi "html\|DOCTYPE"; then
    err "Webhook 返回 HTML（Control UI），说明路由未注册"
    echo ""
    echo "详细响应:"
    echo "$RESPONSE" | head -5
    echo ""
    echo "可能的原因:"
    echo "  1. OpenClaw 版本不支持 WeCom 插件的 HTTP handler API"
    echo "  2. 插件版本与 OpenClaw 不兼容"
    echo ""
    echo "检查版本:"
    openclaw --version
    echo "WeCom 插件版本: $(openclaw plugins list 2>&1 | grep wecom | awk '{print $NF}')"
    echo ""
    echo "尝试重新安装插件:"
    echo "  openclaw plugins uninstall wecom"
    echo "  openclaw plugins install @sunnoy/wecom@latest"
    echo "  bash $0"
    exit 1
elif echo "$RESPONSE" | grep -qi "503\|error"; then
    warn "Webhook 返回错误"
    echo "$RESPONSE"
    exit 1
else
    log "Webhook 响应正常（非 HTML）"
    echo "响应前 100 字符: ${RESPONSE:0:100}"
fi

step "验证 socat 端口转发"

if ! systemctl is-active openclaw-port-forward &>/dev/null; then
    warn "socat 端口转发服务未运行"
    if systemctl list-unit-files | grep -q openclaw-port-forward; then
        systemctl start openclaw-port-forward
        log "已启动端口转发服务"
    else
        err "端口转发服务未安装，请先运行 install-socat-forward.sh"
        exit 1
    fi
else
    log "socat 端口转发服务运行正常"
fi

step "最终状态"

echo ""
openclaw status 2>&1 | grep -A2 "WeCom"
echo ""

echo "${GREEN}╔══════════════════════════════════════════════════════════════╗"
echo "║  诊断完成                                                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  现在去企业微信管理后台点【保存】                             ║"
echo "║  URL: https://tslcz.com/webhooks/wecom                       ║"
echo "║                                                              ║"
echo "║  如果还是失败，可能是 OpenClaw 版本不兼容。                   ║"
echo "║  建议升级: npm update -g openclaw@latest                      ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝${NC}"
