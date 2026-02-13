#!/bin/bash
###############################################################################
#  OpenClaw 企业微信渠道一键部署脚本
#
#  功能: 安装 WeCom 插件 + 配置 Nginx webhook + 对接企业微信应用
#  前提: OpenClaw 已安装 (版本 >= 2026.1.30), 域名有 SSL 证书
#
#  使用方法:
#    chmod +x setup-wecom-for-openclaw.sh && bash setup-wecom-for-openclaw.sh
#
#  需要提前准备（从企业微信管理后台获取）:
#    - 企业ID (CorpId)
#    - 应用ID (AgentId)
#    - 应用密钥 (Secret)
#    - 接收消息 Token（自己设一个）
#    - 接收消息 EncodingAESKey（管理后台点"随机生成"）
###############################################################################
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${GREEN}========== [$1/6] $2 ==========${NC}"; }

# 检查 root
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 或 sudo 运行此脚本"
fi

###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   OpenClaw 企业微信渠道一键部署                               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
step 1 "检查环境"

# 智能检测 OpenClaw 安装位置
detect_openclaw() {
    # 1. 尝试从 PATH 找
    if command -v openclaw &>/dev/null; then
        OPENCLAW_BIN=$(which openclaw)
        log "检测到 OpenClaw: $OPENCLAW_BIN"
        return 0
    fi

    # 2. 搜索常见安装路径
    local search_paths=(
        "/root/.npm-global/bin/openclaw"
        "/home/*/.npm-global/bin/openclaw"
        "/usr/local/bin/openclaw"
        "$(eval echo ~${SUDO_USER:-root})/.npm-global/bin/openclaw"
    )

    for pattern in "${search_paths[@]}"; do
        for path in $pattern; do
            if [ -f "$path" ] && [ -x "$path" ]; then
                OPENCLAW_BIN="$path"
                export PATH="$(dirname "$path"):$PATH"
                log "检测到 OpenClaw: $OPENCLAW_BIN"
                return 0
            fi
        done
    done

    err "未找到 openclaw 命令，请先运行 install-openclaw.sh 安装"
}

detect_openclaw

OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
log "OpenClaw 版本: $OPENCLAW_VERSION"

# 检查 gateway 状态
if ! openclaw status &>/dev/null; then
    err "OpenClaw Gateway 未运行，请先执行 openclaw gateway start"
fi
log "OpenClaw Gateway 运行正常"

# 自动检测域名（从现有 nginx 配置读取）
DOMAIN=""
MATRIX_NGINX_CONF="/opt/matrix/nginx/conf.d/matrix.conf"
if [ -f "$MATRIX_NGINX_CONF" ]; then
    DOMAIN=$(grep -m1 'server_name' "$MATRIX_NGINX_CONF" | awk '{print $2}' | tr -d ';' | head -1)
    log "检测到现有 Matrix 部署，域名: $DOMAIN"
else
    warn "未检测到 /opt/matrix/nginx/，将尝试使用系统 nginx"
fi

# 如果自动检测失败，手动输入
if [ -z "$DOMAIN" ]; then
    echo ""
    read -p "请输入你的主域名（如 tslcz.com）: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        err "域名不能为空"
    fi
fi

###############################################################################
step 2 "收集企业微信凭据"

echo ""
echo "请登录企业微信管理后台获取以下信息："
echo "  https://work.weixin.qq.com/"
echo ""

# 重定向到 /dev/tty 以支持 curl|bash 场景
read -p "企业ID (CorpId): " CORP_ID </dev/tty
read -p "应用ID (AgentId): " AGENT_ID </dev/tty
read -sp "应用密钥 (Secret): " SECRET </dev/tty
echo ""
read -p "接收消息 Token（自己设一个，如 openclaw2026）: " WECOM_TOKEN </dev/tty
read -p "EncodingAESKey（43位，管理后台点随机生成）: " AES_KEY </dev/tty

# 验证输入
if [ -z "$CORP_ID" ] || [ -z "$AGENT_ID" ] || [ -z "$SECRET" ] || [ -z "$WECOM_TOKEN" ] || [ -z "$AES_KEY" ]; then
    err "所有字段都必须填写"
fi

if [ ${#AES_KEY} -ne 43 ]; then
    err "EncodingAESKey 必须是 43 位字符"
fi

log "企业微信凭据已收集"

###############################################################################
step 3 "安装企业微信插件"

echo "  正在安装 @sunnoy/wecom 插件（可能需要1-2分钟）..."
if openclaw plugins list 2>/dev/null | grep -q '@sunnoy/wecom'; then
    log "插件已安装，跳过"
else
    # 尝试安装，如果失败则用 npm 手动装
    if ! openclaw plugins install @sunnoy/wecom 2>&1; then
        warn "openclaw plugins install 失败，尝试手动 npm 安装..."
        OPENCLAW_DIR=$(dirname "$(dirname "$(readlink -f "$(which openclaw)")")")
        cd "$OPENCLAW_DIR"
        npm install @sunnoy/wecom --save 2>&1 | tail -5
    fi
    log "企业微信插件安装完成"
fi

###############################################################################
step 4 "配置 OpenClaw"

openclaw config set plugins.entries.wecom.enabled true
openclaw config set channels.wecom.enabled true
openclaw config set channels.wecom.corpId "$CORP_ID"
openclaw config set channels.wecom.agentId "$AGENT_ID"
openclaw config set channels.wecom.secret "$SECRET"
openclaw config set channels.wecom.token "$WECOM_TOKEN"
openclaw config set channels.wecom.encodingAesKey "$AES_KEY"

# 可选：管理员白名单和指令开关（默认开启）
openclaw config set channels.wecom.commands.enabled true 2>/dev/null || true
openclaw config set channels.wecom.commands.allowlist '["/new","/status","/help","/compact"]' 2>/dev/null || true

log "OpenClaw 企业微信渠道配置完成"

# 验证配置
echo "  当前配置:"
openclaw config get channels.wecom 2>/dev/null | head -8 || true

###############################################################################
step 5 "配置 Nginx webhook 反向代理"

WEBHOOK_URL="https://${DOMAIN}/webhooks/wecom"

# 检测现有 nginx 配置方式
if [ -f "$MATRIX_NGINX_CONF" ]; then
    # 方案 A: 在 Matrix Docker nginx 里加 webhook 路由
    log "检测到 Matrix nginx 配置，添加 webhook 路由..."

    # 检查是否已添加
    if grep -q 'location /webhooks/' "$MATRIX_NGINX_CONF"; then
        warn "webhook 路由已存在，跳过"
    else
        # 找到主域名的 server 块，在最后的 } 前面插入 webhook location
        # 使用 awk 在第一个匹配 $DOMAIN 的 server 块的最后一个 } 前插入
        awk -v domain="$DOMAIN" -v block='
    # OpenClaw 企业微信 webhook
    location /webhooks/ {
        proxy_pass http://host.docker.internal:18789;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }' '
        BEGIN { in_server=0; added=0 }
        /server_name.*'"$DOMAIN"'/ { in_server=1 }
        in_server && /^}/ && !added {
            print block
            added=1
            in_server=0
        }
        { print }
        ' "$MATRIX_NGINX_CONF" > /tmp/matrix.conf.new

        mv /tmp/matrix.conf.new "$MATRIX_NGINX_CONF"

        # 重启 nginx 容器
        docker restart matrix-nginx 2>/dev/null || true
        sleep 2
        log "Nginx webhook 路由已添加并重启"
    fi

elif command -v nginx &>/dev/null && [ -d "/etc/nginx/sites-available" ]; then
    # 方案 B: 使用系统 nginx
    log "使用系统 nginx，配置 webhook 路由..."

    NGINX_CONF="/etc/nginx/sites-available/openclaw-webhook"
    if [ ! -f "$NGINX_CONF" ]; then
        cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /webhooks/ {
        proxy_pass http://localhost:18789;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

        # 测试配置并重载
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            log "系统 nginx 已配置 webhook 路由"
        else
            err "nginx 配置测试失败，请检查语法"
        fi

        # 如果有 certbot，自动签证书
        if command -v certbot &>/dev/null; then
            warn "正在为 $DOMAIN 签发 SSL 证书（如已有会跳过）..."
            certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || true
        fi
    else
        warn "webhook nginx 配置已存在，跳过"
    fi

else
    err "未检测到可用的 nginx，请手动配置反向代理:\n  URL: $WEBHOOK_URL\n  后端: http://localhost:18789/webhooks/wecom"
fi

log "Webhook URL: $WEBHOOK_URL"

###############################################################################
step 6 "重启 OpenClaw Gateway 并验证"

echo "  重启 gateway..."
systemctl restart openclaw-gateway 2>/dev/null || openclaw gateway restart 2>/dev/null || true
sleep 5

# 验证
echo ""
echo "========================================="
echo "  OpenClaw 渠道状态"
echo "========================================="
openclaw status 2>&1 | grep -A8 "Channels" || true

echo ""
echo "--- WeCom 日志 (最近5条) ---"
tail -20 ~/.openclaw/logs/*.log 2>/dev/null | grep -i wecom | tail -5 || echo "  (暂无日志，发送消息后会出现)"

###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  企业微信渠道配置完成!                                        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Webhook URL:  ${WEBHOOK_URL}"
echo "║                                                              ║"
echo "║  下一步（企业微信管理后台操作）:                              ║"
echo "║                                                              ║"
echo "║  1. 打开 https://work.weixin.qq.com/                         ║"
echo "║  2. 进入你的应用 → 接收消息 → 设置API接收                     ║"
echo "║  3. 填写:                                                     ║"
echo "║     URL: ${WEBHOOK_URL}"
echo "║     Token: ${WECOM_TOKEN}"
echo "║     EncodingAESKey: ${AES_KEY}"
echo "║  4. 点击【保存】（会触发验证，应该显示绿色✓）                  ║"
echo "║  5. 在企业微信 APP 打开应用，发消息测试                       ║"
echo "║                                                              ║"
echo "║  验证命令:                                                    ║"
echo "║    openclaw status                # 查看 wecom 渠道状态       ║"
echo "║    tail -f ~/.openclaw/logs/*.log # 查看实时日志              ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# 自动测试 webhook 可达性（可选）
echo "${YELLOW}[测试] 检查 webhook 可达性...${NC}"
if curl -sf "$WEBHOOK_URL" -o /dev/null 2>&1; then
    log "Webhook URL 可访问（返回非错误状态码）"
else
    warn "Webhook URL 访问测试失败，请检查 nginx 和防火墙配置"
fi
