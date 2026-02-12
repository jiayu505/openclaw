#!/bin/bash
###############################################################################
#  OpenClaw Matrix 渠道一键部署脚本
#  
#  功能: Synapse + Element Web + Nginx + SSL + OpenClaw对接，一条龙
#  前提: Ubuntu 22.04+, OpenClaw 已安装且 gateway 在跑, 域名已解析到本机IP
#
#  使用方法:
#    1. 修改下面 ===配置区=== 里的变量
#    2. chmod +x setup-matrix-for-openclaw.sh
#    3. bash setup-matrix-for-openclaw.sh
#
#  踩坑记录 (2026-02-12):
#    - OpenClaw Matrix 插件配置字段是 "homeserver"，不是 "homeserverUrl"!
#    - 需要手动安装 @vector-im/matrix-bot-sdk 到 openclaw 的 node_modules
#    - 配对(pairing)需要在 Element 里发消息触发后手动 approve
###############################################################################
set -euo pipefail

# ========================= 配置区 (按需修改) =========================
DOMAIN="tslcz.com"                    # 主域名 (Element Web 入口)
MATRIX_DOMAIN="matrix.tslcz.com"      # Synapse API 子域名
BOT_USER="openclaw"                   # Matrix 机器人用户名
BOT_PASSWORD="openclaw-bot-2026"      # Matrix 机器人密码 (随便设，后面自动获取token)
ADMIN_EMAIL="admin@tslcz.com"         # Let's Encrypt 证书邮箱
ELEMENT_BRAND="甲鱼 Chat"             # Element Web 显示名称
MATRIX_DIR="/opt/matrix"              # 部署目录
OPENCLAW_DIR=""                       # OpenClaw 安装目录 (留空=自动检测)
# =====================================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${GREEN}========== [$1/10] $2 ==========${NC}"; }

# 自动检测 OpenClaw 安装目录
detect_openclaw_dir() {
    if [ -n "$OPENCLAW_DIR" ]; then return; fi
    local oc_bin
    oc_bin=$(which openclaw 2>/dev/null || true)
    if [ -z "$oc_bin" ]; then
        err "找不到 openclaw 命令，请确认已安装 OpenClaw"
    fi
    # 跟踪符号链接找到真实目录
    local real_bin
    real_bin=$(readlink -f "$oc_bin")
    OPENCLAW_DIR=$(dirname "$(dirname "$real_bin")")
    # 验证
    if [ ! -f "$OPENCLAW_DIR/package.json" ]; then
        # 常见位置
        for dir in /root/.npm-global/lib/node_modules/openclaw /usr/local/lib/node_modules/openclaw; do
            if [ -f "$dir/package.json" ]; then
                OPENCLAW_DIR="$dir"
                return
            fi
        done
        err "无法定位 OpenClaw 的 node_modules 目录，请手动设置 OPENCLAW_DIR"
    fi
}

###############################################################################
# 开始
###############################################################################
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   OpenClaw Matrix 渠道一键部署               ║"
echo "║   域名: $DOMAIN / $MATRIX_DOMAIN"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 检查 root
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 或 sudo 运行此脚本"
fi

detect_openclaw_dir
log "OpenClaw 目录: $OPENCLAW_DIR"

# 检查域名解析
step 1 "检查环境"
echo "  检查域名解析..."
for d in "$DOMAIN" "$MATRIX_DOMAIN"; do
    if ! host "$d" >/dev/null 2>&1; then
        err "域名 $d 未解析，请先添加 A 记录指向本机 IP"
    fi
done
log "域名解析正常"

# 检查端口
for port in 80 443; do
    if ss -tlnp | grep -q ":${port} "; then
        warn "端口 $port 被占用，尝试停止..."
        # 常见占用者
        systemctl stop nginx 2>/dev/null || true
        docker stop matrix-nginx 2>/dev/null || true
        sleep 1
        if ss -tlnp | grep -q ":${port} "; then
            err "端口 $port 仍被占用，请手动释放"
        fi
    fi
done
log "端口 80/443 可用"

###############################################################################
step 2 "安装 Docker"
if command -v docker &>/dev/null; then
    log "Docker 已安装: $(docker --version)"
else
    curl -fsSL https://get.docker.com | sh
    log "Docker 安装完成"
fi

###############################################################################
step 3 "部署 Synapse + Element Web + Nginx"

mkdir -p "$MATRIX_DIR"/{synapse,element,nginx/{conf.d,certs}}

# --- 生成 Synapse 配置 ---
if [ ! -f "$MATRIX_DIR/synapse/homeserver.yaml" ]; then
    log "生成 Synapse 配置..."
    docker run --rm \
        -v "$MATRIX_DIR/synapse:/data" \
        -e SYNAPSE_SERVER_NAME="$DOMAIN" \
        -e SYNAPSE_REPORT_STATS=no \
        matrixdotorg/synapse:latest generate
else
    log "Synapse 配置已存在，跳过生成"
fi

# --- 修改 homeserver.yaml：追加注册和公网URL ---
HSYAML="$MATRIX_DIR/synapse/homeserver.yaml"
if ! grep -q "enable_registration:" "$HSYAML"; then
    cat >> "$HSYAML" << YAML
enable_registration: true
enable_registration_without_verification: true
public_baseurl: https://${MATRIX_DOMAIN}/
serve_server_wellknown: true
YAML
    log "homeserver.yaml 已添加注册和公网配置"
else
    log "homeserver.yaml 注册配置已存在"
fi

# --- Element Web 配置 ---
cat > "$MATRIX_DIR/element/config.json" << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${MATRIX_DOMAIN}",
            "server_name": "${DOMAIN}"
        }
    },
    "brand": "${ELEMENT_BRAND}",
    "default_theme": "light",
    "room_directory": {
        "servers": ["${DOMAIN}"]
    }
}
EOF
log "Element Web 配置已写入"

# --- docker-compose.yml ---
cat > "$MATRIX_DIR/docker-compose.yml" << 'EOF'
services:
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    restart: unless-stopped
    volumes:
      - ./synapse:/data
    ports:
      - "8008:8008"

  element:
    image: vectorim/element-web:latest
    container_name: element
    restart: unless-stopped
    volumes:
      - ./element/config.json:/app/config.json:ro
    ports:
      - "8080:80"

  nginx:
    image: nginx:alpine
    container_name: matrix-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - synapse
      - element
EOF
log "docker-compose.yml 已写入"

###############################################################################
step 4 "签发 SSL 证书"

if [ -f "/etc/letsencrypt/live/${MATRIX_DOMAIN}/fullchain.pem" ]; then
    log "SSL 证书已存在"
else
    apt-get install -y certbot >/dev/null 2>&1 || true
    certbot certonly --standalone \
        -d "$MATRIX_DOMAIN" -d "$DOMAIN" \
        --agree-tos --no-eff-email -m "$ADMIN_EMAIL"
    log "SSL 证书签发成功"
fi

# 复制证书到 nginx 目录
cp /etc/letsencrypt/live/"$MATRIX_DOMAIN"/fullchain.pem "$MATRIX_DIR/nginx/certs/"
cp /etc/letsencrypt/live/"$MATRIX_DOMAIN"/privkey.pem "$MATRIX_DIR/nginx/certs/"
log "证书已复制到 nginx 目录"

###############################################################################
step 5 "配置 Nginx 反向代理"

cat > "$MATRIX_DIR/nginx/conf.d/matrix.conf" << EOF
server {
    listen 80;
    server_name ${MATRIX_DOMAIN} ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${MATRIX_DOMAIN};

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    client_max_body_size 50m;

    location / {
        proxy_pass http://synapse:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location / {
        proxy_pass http://element:80;
        proxy_set_header Host \$host;
    }
}
EOF
log "Nginx 配置已写入"

###############################################################################
step 6 "启动 Docker 容器"

cd "$MATRIX_DIR"
docker compose down 2>/dev/null || true
docker compose up -d
sleep 5

# 检查容器状态
ALL_UP=true
for c in synapse element matrix-nginx; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        warn "容器 $c 未运行!"
        ALL_UP=false
    fi
done
if $ALL_UP; then
    log "三个容器全部运行正常"
else
    err "部分容器未启动，请检查: docker compose logs"
fi

###############################################################################
step 7 "创建 Matrix 机器人账号并获取 Access Token"

# 等 Synapse 完全就绪
echo "  等待 Synapse 就绪..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# 注册机器人（不需要管理员权限，如果已存在会报错，忽略）
docker exec synapse register_new_matrix_user \
    -c /data/homeserver.yaml http://localhost:8008 \
    -u "$BOT_USER" -p "$BOT_PASSWORD" --no-admin 2>/dev/null || warn "机器人账号可能已存在，继续"

# 获取 access token
TOKEN_RESPONSE=$(curl -sf -X POST "http://localhost:8008/_matrix/client/v3/login" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"${BOT_USER}\",\"password\":\"${BOT_PASSWORD}\"}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token' 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ]; then
    err "获取 access token 失败! 响应: $TOKEN_RESPONSE"
fi

BOT_USER_ID="@${BOT_USER}:${DOMAIN}"
log "机器人: $BOT_USER_ID"
log "Access Token: ${ACCESS_TOKEN:0:20}..."
warn "公开注册当前已开启（用于你注册自己的账号），配对完成后请务必关闭！见最终提示。"

###############################################################################
step 8 "安装 OpenClaw Matrix 插件依赖"

cd "$OPENCLAW_DIR"
if [ ! -f node_modules/@vector-im/matrix-bot-sdk/package.json ]; then
    npm install @vector-im/matrix-bot-sdk --save 2>/dev/null
    log "matrix-bot-sdk 依赖安装完成"
else
    log "matrix-bot-sdk 依赖已存在"
fi

###############################################################################
step 9 "配置 OpenClaw Matrix 渠道"

# ⚠️ 关键: 字段名是 homeserver 不是 homeserverUrl!
# 这是踩了大坑后确认的，插件源码读的是 account.homeserver
openclaw config set channels.matrix.enabled true
openclaw config set channels.matrix.homeserver "https://${MATRIX_DOMAIN}"
openclaw config set channels.matrix.userId "$BOT_USER_ID"
openclaw config set channels.matrix.accessToken "$ACCESS_TOKEN"

# 清理可能残留的错误配置
openclaw config set channels.matrix.homeserverUrl "" 2>/dev/null || true

# 确保 matrix 插件已启用
openclaw config set plugins.entries.matrix.enabled true 2>/dev/null || true

log "OpenClaw Matrix 配置完成"

# 验证配置
echo "  当前配置:"
openclaw config get channels.matrix 2>/dev/null | head -10

###############################################################################
step 10 "重启 OpenClaw Gateway 并验证"

systemctl restart openclaw-gateway 2>/dev/null || openclaw gateway restart 2>/dev/null || true
echo "  等待 gateway 启动..."
sleep 10

# 验证
echo ""
echo "========================================="
echo "  OpenClaw 渠道状态"
echo "========================================="
openclaw status 2>&1 | grep -A6 "Channels" || true

echo ""
echo "--- Matrix 日志 (最近5条) ---"
cat /tmp/openclaw/openclaw-"$(date +%Y-%m-%d)".log 2>/dev/null | grep -i matrix | tail -5 || echo "  (无日志)"

###############################################################################
# 证书自动续签
cat > "$MATRIX_DIR/renew-certs.sh" << 'RENEW'
#!/bin/bash
certbot renew --quiet
cp /etc/letsencrypt/live/MATRIX_DOMAIN_PLACEHOLDER/fullchain.pem MATRIX_DIR_PLACEHOLDER/nginx/certs/
cp /etc/letsencrypt/live/MATRIX_DOMAIN_PLACEHOLDER/privkey.pem MATRIX_DIR_PLACEHOLDER/nginx/certs/
docker restart matrix-nginx
RENEW
sed -i "s|MATRIX_DOMAIN_PLACEHOLDER|${MATRIX_DOMAIN}|g" "$MATRIX_DIR/renew-certs.sh"
sed -i "s|MATRIX_DIR_PLACEHOLDER|${MATRIX_DIR}|g" "$MATRIX_DIR/renew-certs.sh"
chmod +x "$MATRIX_DIR/renew-certs.sh"
(crontab -l 2>/dev/null | grep -v renew-certs; echo "0 3 * * * ${MATRIX_DIR}/renew-certs.sh") | crontab -

###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  部署完成!                                                    ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Element Web:  https://${DOMAIN}                             "
echo "║  Synapse API:  https://${MATRIX_DOMAIN}                      "
echo "║  机器人账号:   ${BOT_USER_ID}                                "
echo "║                                                              ║"
echo "║  下一步:                                                      ║"
echo "║  1. 浏览器打开 https://${DOMAIN} 注册你的用户账号             "
echo "║  2. 创建一个聊天室                                            ║"
echo "║  3. 在聊天室输入: /invite ${BOT_USER_ID}                     "
echo "║  4. 发一条消息，机器人会回复 pairing code                     ║"
echo "║  5. 回到服务器执行:                                           ║"
echo "║     openclaw pairing approve matrix <配对码>                  ║"
echo "║  6. 再发消息测试，机器人就能正常回复了!                       ║"
echo "║                                                              ║"
echo "║  ⚠ 配对完成后，关闭公开注册（重要!）:                       ║"
echo "║     sed -i 's/enable_registration: true/enable_registration: false/' $HSYAML"
echo "║     sed -i 's/enable_registration_without_verification: true/enable_registration_without_verification: false/' $HSYAML"
echo "║     docker restart synapse                                   ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
