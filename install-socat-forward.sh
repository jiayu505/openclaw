#!/bin/bash
# 安装并配置 socat 端口转发服务

set -e

echo "正在创建 systemd 服务..."

cat > /etc/systemd/system/openclaw-port-forward.service << 'SYSTEMD_SERVICE'
[Unit]
Description=Forward Docker bridge to OpenClaw Gateway
After=network.target docker.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:18789,bind=172.17.0.1,reuseaddr,fork TCP:127.0.0.1:18789
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE

echo "✓ 服务文件已创建"

systemctl daemon-reload
systemctl enable openclaw-port-forward
systemctl restart openclaw-port-forward

echo ""
echo "✓ 服务已启动并设置为开机自启"
echo ""
echo "状态检查:"
systemctl status openclaw-port-forward --no-pager -l
echo ""
echo "现在可以去企业微信管理后台保存配置了！"
