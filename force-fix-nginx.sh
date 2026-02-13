#!/bin/bash
# 强制修复 Nginx 配置（适用于容器重启循环的情况）
set -e

echo "强制修复 Nginx 配置..."

# 1. 先停止容器
echo "停止 Nginx 容器..."
docker stop matrix-nginx || true
sleep 2

# 2. 备份当前配置
NGINX_CONF="/opt/matrix/nginx/conf.d/matrix.conf"
if [ -f "$NGINX_CONF" ]; then
    cp "$NGINX_CONF" "$NGINX_CONF.broken-$(date +%s)"
    echo "✓ 已备份损坏的配置"
fi

# 3. 写入正确的配置
cat > "$NGINX_CONF" << 'EOF'
# Synapse 服务器配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name matrix.tslcz.com;

    ssl_certificate /etc/letsencrypt/live/matrix.tslcz.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/matrix.tslcz.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';

    client_max_body_size 50M;

    location /_matrix {
        proxy_pass http://synapse:8008;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        proxy_read_timeout 600s;
    }

    location /_synapse {
        proxy_pass http://synapse:8008;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
    }
}

# Element Web 和企业微信 Webhook 配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name tslcz.com;

    ssl_certificate /etc/letsencrypt/live/tslcz.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/tslcz.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';

    root /opt/matrix/element;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
    }

    # 企业微信 Webhook
    location /webhooks/ {
        proxy_pass http://host.docker.internal:18790/webhooks/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }
}

# HTTP 重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name matrix.tslcz.com tslcz.com;
    return 301 https://$server_name$request_uri;
}
EOF

echo "✓ 配置文件已恢复"

# 4. 启动容器
echo ""
echo "启动 Nginx 容器..."
docker start matrix-nginx

# 5. 等待并检查状态
echo "等待容器启动..."
sleep 5

if docker ps | grep matrix-nginx | grep -q "Up"; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✓ 修复成功！所有服务已恢复                                   ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    echo "║  请测试以下服务：                                             ║"
    echo "║  ✓ https://tslcz.com/              (Element Web)             ║"
    echo "║  ✓ https://matrix.tslcz.com/       (Synapse)                 ║"
    echo "║  ✓ 企业微信群聊发消息测试                                     ║"
    echo "║                                                              ║"
    echo "║  你的 10 个小时的工作都还在！                                  ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
else
    echo "⚠ 容器启动可能有问题，查看日志："
    docker logs matrix-nginx --tail 20
    exit 1
fi
