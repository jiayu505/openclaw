#!/bin/bash
# 替换 matrix.conf 配置文件的脚本

set -e

echo "开始替换 matrix.conf..."

# 备份原配置
cp /opt/matrix/nginx/conf.d/matrix.conf /opt/matrix/nginx/conf.d/matrix.conf.backup.$(date +%Y%m%d_%H%M%S)
echo "✓ 已备份原配置"

# 写入新配置
cat > /opt/matrix/nginx/conf.d/matrix.conf << 'EOF'
server {
    listen 80;
    server_name matrix.tslcz.com tslcz.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name matrix.tslcz.com;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    client_max_body_size 50m;

    location / {
        proxy_pass http://synapse:8008;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
    }
}

server {
    listen 443 ssl;
    server_name tslcz.com;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location / {
        proxy_pass http://element:80;
        proxy_set_header Host $host;
    }

    # OpenClaw 企业微信 webhook
    location /webhooks/ {
        proxy_pass http://host.docker.internal:18789;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

echo "✓ 配置已替换"

# 重启 nginx
docker restart matrix-nginx
echo "✓ nginx 已重启"

# 测试
echo ""
echo "测试 webhook 可达性..."
sleep 2
curl -I https://tslcz.com/webhooks/wecom

echo ""
echo "完成！现在可以去企业微信管理后台保存配置了。"
echo "URL: https://tslcz.com/webhooks/wecom"
