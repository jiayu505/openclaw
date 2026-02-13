#!/bin/bash
# 详细检查证书情况

echo "1. 检查所有证书..."
ls -la /etc/letsencrypt/live/

echo ""
echo "2. 检查 /opt/matrix 下是否有证书..."
find /opt/matrix -name "*.pem" -o -name "*.crt" -o -name "*.key" 2>/dev/null

echo ""
echo "3. 检查 Docker Compose 配置..."
if [ -f /opt/matrix/docker-compose.yml ]; then
    echo "Docker Compose 文件存在，查看 Nginx 卷挂载："
    grep -A 10 "matrix-nginx" /opt/matrix/docker-compose.yml
fi

echo ""
echo "4. 查看 Nginx 容器完整配置..."
docker inspect matrix-nginx --format '{{json .Mounts}}' | python3 -m json.tool
