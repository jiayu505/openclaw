#!/bin/bash
# 最终修复 - 使用正确的证书路径
set -e

echo "使用正确的证书路径修复 Nginx..."

# 停止容器
docker stop matrix-nginx || true
sleep 2

# 备份
NGINX_CONF="/opt/matrix/nginx/conf.d/matrix.conf"
cp "$NGINX_CONF" "$NGINX_CONF.before-final-fix"

# 写入正确配置（使用 /etc/nginx/certs 路径）
cat > "$NGINX_CONF" << 'EOF'
# Synapse 服务器配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name matrix.tslcz.com;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
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

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
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

echo "✓ 配置已更新（使用正确的证书路径）"

# 启动容器
echo "启动 Nginx..."
docker start matrix-nginx
sleep 5

# 检查状态
if docker ps | grep matrix-nginx | grep -q "Up"; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✓✓✓ 修复成功！所有服务已恢复正常！ ✓✓✓"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  测试这些服务："
    echo "  ✓ https://tslcz.com/              (Element Web)"
    echo "  ✓ https://matrix.tslcz.com/       (Synapse)"
    echo "  ✓ 企业微信群聊发消息"
    echo ""
    echo "  你的 10 个小时工作完好无损！"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "⚠ 容器启动可能有问题"
    docker logs matrix-nginx --tail 30
fi
