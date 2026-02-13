#!/bin/bash
# 诊断证书问题

echo "1. 检查宿主机上的证书文件..."
ls -la /etc/letsencrypt/live/matrix.tslcz.com/ 2>/dev/null || echo "⚠ 证书目录不存在"
ls -la /etc/letsencrypt/live/tslcz.com/ 2>/dev/null || echo "⚠ 证书目录不存在"

echo ""
echo "2. 检查 Nginx 容器的挂载..."
docker inspect matrix-nginx | grep -A 20 "Mounts"

echo ""
echo "3. 查看之前工作的配置备份..."
OLDER_BACKUP=$(ls -t /opt/matrix/nginx/conf.d/matrix.conf.broken-* 2>/dev/null | tail -1)
if [ -n "$OLDER_BACKUP" ]; then
    echo "最早的备份文件: $OLDER_BACKUP"
    echo "查看 SSL 配置部分："
    grep -A 2 "ssl_certificate" "$OLDER_BACKUP" | head -6
fi

echo ""
echo "4. 检查是否有其他备份配置..."
ls -lh /opt/matrix/nginx/conf.d/*.backup 2>/dev/null || echo "没有 .backup 文件"
ls -lh /opt/matrix/nginx/conf.d/*.bak 2>/dev/null || echo "没有 .bak 文件"
ls -lh /opt/matrix/nginx/conf.d/*.old 2>/dev/null || echo "没有 .old 文件"
