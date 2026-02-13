#!/bin/bash
# 部署 OpenClaw AI 应用主页
set -e

echo "部署 OpenClaw AI 应用主页..."

# 创建网页目录
mkdir -p /var/www/openclaw

# 下载主页文件
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/openclaw-homepage.html -o /var/www/openclaw/index.html

echo "✓ 主页文件已下载"

# 配置 Nginx（添加到现有配置）
NGINX_CONF="/opt/matrix/nginx/conf.d/matrix.conf"

if [ -f "$NGINX_CONF" ]; then
    # 检查是否已配置
    if grep -q "location /openclaw-ai" "$NGINX_CONF"; then
        echo "✓ Nginx 配置已存在"
    else
        # 在 tslcz.com 的 server 块中添加 location
        sed -i '/server_name tslcz.com;/,/^}$/ {
            /location \/webhooks\//a\
\
    # OpenClaw AI 应用主页\
    location /openclaw-ai {\
        alias /var/www/openclaw;\
        index index.html;\
        try_files $uri $uri/ =404;\
    }
        }' "$NGINX_CONF"

        echo "✓ Nginx 配置已添加"

        # 重启 nginx
        docker restart matrix-nginx
        echo "✓ Nginx 已重启"
    fi
else
    echo "⚠ 未找到 Nginx 配置，请手动配置"
    echo "配置示例："
    echo "  location /openclaw-ai {"
    echo "      alias /var/www/openclaw;"
    echo "      index index.html;"
    echo "  }"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  应用主页部署完成！                                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  主页 URL: https://tslcz.com/openclaw-ai                     ║"
echo "║                                                              ║"
echo "║  接下来：                                                     ║"
echo "║  1. 访问 https://tslcz.com/openclaw-ai 测试                  ║"
echo "║  2. 去企业微信后台配置应用主页                                ║"
echo "║  3. 填入上面的 URL 并保存                                     ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
