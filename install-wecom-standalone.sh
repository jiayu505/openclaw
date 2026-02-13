#!/bin/bash
###############################################################################
# 企业微信 Webhook 独立服务安装脚本
# 不依赖 OpenClaw 插件，直接处理企业微信回调
###############################################################################
set -e

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   企业微信 Webhook 独立服务安装                               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

step "安装依赖"

if ! command -v node &>/dev/null; then
    err "Node.js 未安装，请先安装 Node.js 18+"
fi

NODE_VERSION=$(node --version | grep -oP '\d+' | head -1)
if [ "$NODE_VERSION" -lt 18 ]; then
    err "Node.js 版本过低（需要 18+），当前: $(node --version)"
fi

log "Node.js: $(node --version)"

# 安装 Express
npm install -g express
log "Express 已安装"

step "下载服务脚本"

SCRIPT_URL="https://raw.githubusercontent.com/jiayu505/openclaw/master/wecom-webhook-standalone.js"
INSTALL_DIR="/opt/wecom-webhook"
mkdir -p "$INSTALL_DIR"

curl -fsSL "$SCRIPT_URL" -o "$INSTALL_DIR/server.js"
chmod +x "$INSTALL_DIR/server.js"
log "服务脚本已下载到 $INSTALL_DIR/server.js"

step "配置环境变量"

read -p "企业ID (CorpId): " CORP_ID </dev/tty
read -p "应用ID (AgentId): " AGENT_ID </dev/tty
read -sp "应用密钥 (Secret): " SECRET </dev/tty
echo ""
read -p "Token (自己设的，如 openclaw2026): " TOKEN </dev/tty
read -p "EncodingAESKey (43位): " AES_KEY </dev/tty

if [ -z "$CORP_ID" ] || [ -z "$AGENT_ID" ] || [ -z "$SECRET" ] || [ -z "$TOKEN" ] || [ -z "$AES_KEY" ]; then
    err "所有字段都必须填写"
fi

# 创建环境变量文件
cat > "$INSTALL_DIR/.env" << EOF
WECOM_CORP_ID=$CORP_ID
WECOM_AGENT_ID=$AGENT_ID
WECOM_SECRET=$SECRET
WECOM_TOKEN=$TOKEN
WECOM_AES_KEY=$AES_KEY
PORT=18790
EOF

log "环境变量已保存"

step "创建 systemd 服务"

cat > /etc/systemd/system/wecom-webhook.service << EOF
[Unit]
Description=WeCom Webhook Standalone Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=/usr/bin/node $INSTALL_DIR/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wecom-webhook
systemctl start wecom-webhook

log "systemd 服务已启动"

step "更新 Nginx 配置"

# 更新 matrix.conf 的 webhook 代理目标
NGINX_CONF="/opt/matrix/nginx/conf.d/matrix.conf"
if [ -f "$NGINX_CONF" ]; then
    # 替换 proxy_pass 目标为新端口
    sed -i 's|proxy_pass http://host.docker.internal:18789;|proxy_pass http://host.docker.internal:18790;|g' "$NGINX_CONF"
    docker restart matrix-nginx 2>/dev/null || true
    log "Nginx 配置已更新，指向新服务（端口 18790）"
else
    warn "未找到 $NGINX_CONF，请手动配置 Nginx 转发到 127.0.0.1:18790"
fi

step "验证服务"

sleep 2
if systemctl is-active wecom-webhook &>/dev/null; then
    log "服务运行正常"
else
    err "服务启动失败，查看日志: journalctl -u wecom-webhook -n 50"
fi

# 测试健康检查
if curl -sf http://127.0.0.1:18790/health &>/dev/null; then
    log "健康检查通过"
else
    warn "健康检查失败"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  安装完成！                                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  服务已启动在端口 18790                                       ║"
echo "║  Webhook URL: https://tslcz.com/webhooks/wecom               ║"
echo "║                                                              ║"
echo "║  现在去企业微信后台保存配置：                                 ║"
echo "║    URL: https://tslcz.com/webhooks/wecom                     ║"
echo "║    Token: $TOKEN"
echo "║    EncodingAESKey: $AES_KEY"
echo "║                                                              ║"
echo "║  查看日志:                                                    ║"
echo "║    journalctl -u wecom-webhook -f                            ║"
echo "║                                                              ║"
echo "║  重启服务:                                                    ║"
echo "║    systemctl restart wecom-webhook                           ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
