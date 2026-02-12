#!/usr/bin/env bash
#============================================================================
# OpenClaw 一键安装脚本
# 适用于: AWS Lightsail Ubuntu 22.04 LTS (4h16g)
#
# 一键安装（GitHub 托管后）:
#   curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-openclaw.sh | sudo bash
#
# 或下载后执行:
#   chmod +x install-openclaw.sh && sudo ./install-openclaw.sh
#
# 脚本会自动完成:
#   1. 系统更新 & 依赖安装
#   2. 创建 4GB Swap
#   3. 安装 Node.js 22
#   4. 配置 npm 全局路径
#   5. 安装 OpenClaw
#   6. 配置防火墙（ufw）
#   7. 配置 systemd linger
#
# ⚠️ 注意: onboarding 需要手动交互，脚本结束后会提示你执行。
#============================================================================

set -euo pipefail

# ---------- 颜色输出 ----------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}========== $* ==========${NC}"; }

# ---------- 失败时提示 ----------
cleanup() {
    if [[ $? -ne 0 ]]; then
        echo -e "\n${RED}[✗] 安装过程中出错，请检查上方日志。${NC}"
        echo -e "${YELLOW}    如需重新安装，可直接重新运行此脚本（已完成的步骤会自动跳过）。${NC}"
    fi
}
trap cleanup EXIT

# ---------- 检查 root ----------
if [[ $EUID -ne 0 ]]; then
    err "请使用 sudo 运行此脚本:  sudo ./install-openclaw.sh"
fi

# ---------- 记录实际用户（非 root） ----------
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

if [[ -z "$REAL_HOME" ]]; then
    err "无法获取用户 $REAL_USER 的 home 目录"
fi

if [[ "$REAL_USER" == "root" ]]; then
    warn "检测到直接以 root 登录，建议使用普通用户 + sudo 运行"
fi

# ====================== 步骤 1/7 ======================
step "1/7 系统更新"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
log "系统更新完成"

# ====================== 步骤 2/7 ======================
step "2/7 安装基础依赖"

# 核心依赖（失败则中断）
apt-get install -y -qq \
    curl wget git build-essential ca-certificates \
    lsof unzip jq
log "核心依赖安装完成"

# Chromium 及其运行时依赖（可选，失败不中断）
apt-get install -y -qq \
    chromium-browser \
    libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2 2>/dev/null \
    && log "Chromium 及依赖安装完成" \
    || warn "Chromium 部分依赖安装失败，不影响核心功能"

# ====================== 步骤 3/7 ======================
step "3/7 配置 Swap（4GB）"
if swapon --show | grep -q '/swapfile'; then
    warn "Swap 已存在，跳过"
else
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    # 持久化 fstab
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    # 持久化 sysctl 参数
    cat > /etc/sysctl.d/99-swap-tuning.conf <<SYSCTL
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
    sysctl --system -q
    log "4GB Swap 已创建并启用"
fi

# ====================== 步骤 4/7 ======================
step "4/7 安装 Node.js 22"
if command -v node &>/dev/null && [[ $(node -v | cut -d'v' -f2 | cut -d'.' -f1) -ge 22 ]]; then
    log "Node.js $(node -v) 已安装，跳过"
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    log "Node.js $(node -v) 安装完成"
fi
log "npm 版本: $(npm -v)"

# ====================== 步骤 5/7 ======================
step "5/7 配置 npm 全局路径（避免权限问题）"
sudo -u "$REAL_USER" bash <<USERBLOCK
set -euo pipefail
mkdir -p "\$HOME/.npm-global"
npm config set prefix "\$HOME/.npm-global"

# 写入 PATH（bash / zsh / profile）
for rc in "\$HOME/.bashrc" "\$HOME/.zshrc" "\$HOME/.profile"; do
    if [ -f "\$rc" ] && ! grep -q '.npm-global/bin' "\$rc"; then
        echo 'export PATH="\$HOME/.npm-global/bin:\$PATH"' >> "\$rc"
    fi
done
USERBLOCK
log "npm 全局目录已配置为 $REAL_HOME/.npm-global"

# ====================== 步骤 6/7 ======================
step "6/7 安装 OpenClaw"
sudo -u "$REAL_USER" bash <<'INSTALLBLOCK'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:$PATH"
export SHARP_IGNORE_GLOBAL_LIBVIPS=1

echo "[*] 正在通过 npm 安装 OpenClaw（可能需要 2-5 分钟）..."
npm install -g openclaw@latest 2>&1 | tail -5

if command -v openclaw &>/dev/null; then
    echo "[✓] OpenClaw $(openclaw --version 2>/dev/null || echo '') 安装成功"
else
    echo "[!] npm 安装后命令未找到，尝试官方安装脚本..."
    curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard --no-prompt
fi

# 最终验证
command -v openclaw &>/dev/null || { echo "[✗] OpenClaw 安装失败"; exit 1; }
INSTALLBLOCK
log "OpenClaw 安装完成"

# ====================== 步骤 7/7 ======================
step "7/7 配置防火墙 & systemd"

# 防火墙（仅开放 SSH，OpenClaw 端口不暴露）
if command -v ufw &>/dev/null; then
    ufw allow OpenSSH
    ufw --force enable
    log "防火墙已启用（仅允许 SSH，18789 端口不对外开放）"
else
    warn "ufw 未安装，请自行配置防火墙，勿将 18789 端口暴露到公网"
fi

# systemd linger
loginctl enable-linger "$REAL_USER" 2>/dev/null || true
log "已启用 loginctl linger（服务可在用户注销后持续运行）"

# ====================== 安装完成 ======================
cat <<EOF

${GREEN}╔══════════════════════════════════════════════════════════════╗
║              OpenClaw 安装完成！                             ║
╚══════════════════════════════════════════════════════════════╝${NC}

${CYAN}接下来请执行以下步骤:${NC}

  ${YELLOW}步骤 1: 刷新环境变量${NC}
    source ~/.bashrc

  ${YELLOW}步骤 2: 启动 onboarding 向导（交互式，约 3 分钟）${NC}
    openclaw onboard --install-daemon

    向导会引导你:
    - 选择 AI 模型提供商（Anthropic / OpenAI / Google 等）
    - 输入 API Key
    - 配置消息频道（Telegram / Discord / WhatsApp）
    - 安装 Skills 和 Hooks

  ${YELLOW}步骤 3: 验证安装${NC}
    openclaw doctor        # 检查配置
    openclaw status        # 查看 Gateway 状态

  ${YELLOW}步骤 4: 远程访问 Web 控制台${NC}
    在你的本地电脑上执行 SSH 隧道:
    ${CYAN}ssh -L 18789:localhost:18789 ubuntu@<你的Lightsail公网IP>${NC}
    然后在浏览器打开: ${CYAN}http://localhost:18789${NC}

${RED}安全提醒:${NC}
  - 不要将 18789 端口直接暴露到公网！
  - 始终使用 SSH 隧道或 Tailscale 访问控制台
  - Gateway Token 等同于密码，请妥善保管

EOF

# 如果是终端（非 curl|bash 管道），自动启动 onboarding
if [[ -t 0 ]]; then
    echo -e "${GREEN}正在启动 onboarding 向导...${NC}\n"
    sudo -u "$REAL_USER" -i bash -c 'export PATH="$HOME/.npm-global/bin:$PATH"; openclaw onboard --install-daemon'
else
    echo -e "${YELLOW}检测到通过管道运行，请手动执行 onboarding:${NC}"
    echo -e "  source ~/.bashrc && openclaw onboard --install-daemon\n"
fi
