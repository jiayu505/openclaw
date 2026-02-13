#!/bin/bash
# 检查 Nginx 错误

echo "1. 检查 Nginx 容器状态..."
docker ps | grep matrix-nginx

echo ""
echo "2. 检查 Nginx 错误日志..."
docker logs matrix-nginx --tail 50

echo ""
echo "3. 检查当前配置..."
cat /opt/matrix/nginx/conf.d/matrix.conf

echo ""
echo "4. 检查后端服务状态..."
docker ps | grep -E "(synapse|element)"

echo ""
echo "5. 检查 Element 文件是否存在..."
ls -la /opt/matrix/element/ | head -10
