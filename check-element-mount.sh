#!/bin/bash
# 检查 Element 挂载

echo "1. 检查 Docker Compose 中的 element 挂载..."
grep -A 5 "element:" /opt/matrix/docker-compose.yml

echo ""
echo "2. 检查 Nginx 容器的所有挂载..."
docker inspect matrix-nginx --format '{{range .Mounts}}Source: {{.Source}} -> Destination: {{.Destination}}{{println}}{{end}}'

echo ""
echo "3. 检查宿主机上的 Element 文件..."
ls -la /opt/matrix/element/ | head -20

echo ""
echo "4. 测试容器内是否能访问 Element..."
docker exec matrix-nginx ls -la /opt/matrix/element/ 2>&1 | head -20 || echo "⚠ 容器内路径不存在"

echo ""
echo "5. 检查容器内可能的其他路径..."
docker exec matrix-nginx find / -name "element" -type d 2>/dev/null || true
