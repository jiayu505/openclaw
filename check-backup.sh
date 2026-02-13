#!/bin/bash
# 检查备份的配置文件

echo "查找备份的配置文件..."
ls -lht /opt/matrix/nginx/conf.d/matrix.conf.broken-* | head -1

echo ""
echo "显示最新备份的内容："
LATEST_BACKUP=$(ls -t /opt/matrix/nginx/conf.d/matrix.conf.broken-* | head -1)
cat "$LATEST_BACKUP"
