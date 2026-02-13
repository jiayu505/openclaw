#!/bin/bash
# 紧急修复 Nginx 配置
set -e

echo "紧急修复 Nginx 配置..."

# 备份当前配置（如果存在）
NGINX_CONF="/opt/matrix/nginx/conf.d/matrix.conf"
if [ -f "$NGINX_CONF" ]; then
    cp "$NGINX_CONF" "$NGINX_CONF.broken-$(date +%s)"
    echo "✓ 已备份损坏的配置"
fi

# 写入正确的配置
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

# 测试配置
echo ""
echo "测试 Nginx 配置..."
docker exec matrix-nginx nginx -t

if [ $? -eq 0 ]; then
    echo "✓ 配置文件语法正确"
    echo ""
    echo "重启 Nginx..."
    docker restart matrix-nginx

    # 等待启动
    sleep 3

    # 检查状态
    if docker ps | grep matrix-nginx | grep -q "Up"; then
        echo "✓ Nginx 已成功重启"
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  修复完成！                                                   ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║                                                              ║"
        echo "║  请测试以下服务：                                             ║"
        echo "║  ✓ https://tslcz.com/              (Element Web)             ║"
        echo "║  ✓ https://matrix.tslcz.com/       (Synapse)                 ║"
        echo "║  ✓ https://tslcz.com/webhooks/wecom (企业微信)               ║"
        echo "║                                                              ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
    else
        echo "⚠ Nginx 可能未正常启动，请检查日志："
        echo "docker logs matrix-nginx"
    fi
else
    echo "✗ 配置文件有错误，请查看上面的错误信息"
    exit 1
fi
