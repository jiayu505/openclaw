# OpenClaw 一键部署工具包

### 几条命令，从零到一个能聊天的 AI 助手（Matrix / 企业微信）。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Ubuntu-22.04+-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-Latest-FF6B6B)](https://openclaw.ai)
[![Matrix](https://img.shields.io/badge/Matrix-Synapse-0DBD8B?logo=matrix&logoColor=white)](https://matrix.org)
[![WeCom](https://img.shields.io/badge/企业微信-WeCom-07C160?logo=wechat&logoColor=white)](https://work.weixin.qq.com)

---

## 这是什么？

[OpenClaw](https://openclaw.ai) 是一个开源的 AI 助手，跑在你自己的服务器上，通过聊天软件（Matrix / 企业微信 / Telegram / WhatsApp / Discord）跟它对话，它帮你干活。

本仓库提供三个脚本，让你在云服务器上**无脑部署**：

| 脚本 | 干什么 |
|------|--------|
| `install-openclaw.sh` | 装 OpenClaw（含 Node.js、Swap、防火墙，全自动） |
| `setup-matrix-for-openclaw.sh` | 装 Matrix 聊天服务（Synapse + Element 网页版 + SSL 证书，全自动） |
| `setup-wecom-for-openclaw.sh` | 对接企业微信应用（插件 + webhook + 配置，半自动） |

---

## 你需要准备什么

- 一台 Ubuntu 22.04 云服务器（推荐 AWS Lightsail 4核16G）
- 一个 AI 模型的 API Key（Anthropic / OpenAI / Google 任选）
- （装 Matrix 的话）两个域名解析到服务器 IP

---

## 第一步：安装 OpenClaw

SSH 登录服务器，复制粘贴这一行：

```bash
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-openclaw.sh | sudo bash
```

跑完后执行：

```bash
source ~/.bashrc
openclaw onboard --install-daemon
```

跟着向导选模型、填 API Key 就行了。

> 验证：`openclaw doctor` 和 `openclaw status` 都没报错就 OK。

---

## 第二步：部署 Matrix 聊天频道（可选）

如果你想通过网页聊天室跟 AI 对话，继续装 Matrix。

### 2.1 准备域名

添加两条 A 记录指向你的服务器 IP：

```
tslcz.com        →  你的服务器IP
matrix.tslcz.com →  你的服务器IP
```

### 2.2 修改脚本配置

下载脚本后，打开文件改顶部几个变量（域名、邮箱、密码）：

```bash
wget https://raw.githubusercontent.com/jiayu505/openclaw/master/setup-matrix-for-openclaw.sh
nano setup-matrix-for-openclaw.sh   # 改前几行的配置
```

### 2.3 一键运行

```bash
chmod +x setup-matrix-for-openclaw.sh && sudo bash setup-matrix-for-openclaw.sh
```

### 2.4 配对（唯一需要手动做的事）

1. 浏览器打开 `https://你的域名`，注册一个账号
2. 新建聊天室
3. 输入 `/invite @openclaw:你的域名` 邀请机器人
4. 随便发一条消息，机器人会回复一个配对码
5. 回到服务器执行：

```bash
openclaw pairing approve matrix <配对码>
```

6. 再发消息，AI 就能回复了

### 2.5 关闭公开注册（重要！）

配对完成后，**必须**执行以下命令关闭注册，否则任何人都能注册你的服务器：

```bash
sed -i 's/enable_registration: true/enable_registration: false/' /opt/matrix/synapse/homeserver.yaml
sed -i 's/enable_registration_without_verification: true/enable_registration_without_verification: false/' /opt/matrix/synapse/homeserver.yaml
docker restart synapse
```

> 以后想再开放注册（比如给朋友注册账号），执行：
>
> ```bash
> sed -i 's/enable_registration: false/enable_registration: true/' /opt/matrix/synapse/homeserver.yaml
> sed -i 's/enable_registration_without_verification: false/enable_registration_without_verification: true/' /opt/matrix/synapse/homeserver.yaml
> docker restart synapse
> ```
>
> 注册完后记得再关掉。

---

## 第三步：对接企业微信（可选）

如果你的团队用企业微信办公，可以把 AI 助手接入企业微信应用。

### 3.1 在企业微信管理后台创建应用

1. 登录 [企业微信管理后台](https://work.weixin.qq.com/)
2. **应用管理** → **创建应用** → 选 **智能机器人**
3. 记下：
   - **CorpId**（企业 ID，在"我的企业"页面）
   - **AgentId**（应用 ID）
   - **Secret**（应用密钥）
4. 在"接收消息"配置页面，先随便填个 Token（如 `openclaw2026`），点"随机生成" EncodingAESKey（43位），**先不要点保存**（URL 还没配好）

### 3.2 运行脚本

```bash
chmod +x setup-wecom-for-openclaw.sh && sudo bash setup-wecom-for-openclaw.sh
```

脚本会：
- 交互式输入刚才的凭据
- 安装 `@sunnoy/wecom` 插件
- 自动配置 OpenClaw
- 在现有 nginx 加上 `/webhooks/wecom` 路由
- 重启 gateway

### 3.3 完成企业微信配置

脚本跑完后，回到企业微信管理后台：

1. **URL** 填：`https://你的域名/webhooks/wecom`
2. **Token** 和 **EncodingAESKey** 跟脚本里输入的一致
3. 点**保存**（会验证，显示绿色 ✓）
4. 在企业微信 APP 打开应用，发消息测试

> 验证：`openclaw status` 应该显示 `wecom: connected`

---

## 架构一览

```
你的浏览器
  │
  ▼
Element Web ◄── https://你的域名
  │
  ▼
Nginx (SSL)
  │
  └──► Synapse (Matrix 服务器) ◄── https://matrix.你的域名
          ▲
          │
          │ (http://localhost:8008 直连，不过 nginx)
          │
     OpenClaw 机器人
          ▲
          │
     OpenClaw Gateway ◄── SSH 隧道访问控制台 (端口 18789)
```

---

## 常见问题

| 问题 | 解决办法 |
|------|----------|
| `openclaw: command not found` | 执行 `source ~/.bashrc` |
| npm 安装卡住 | `free -h` 查看内存，确认 swap 已启用 |
| 证书签发失败 | 确认 80 端口没被占用，域名已解析 |
| 机器人不回复 | 检查 `openclaw status`，确认 Matrix 渠道显示 connected |
| 控制台怎么访问 | **不要**开放 18789 端口！用 SSH 隧道：`ssh -L 18789:localhost:18789 ubuntu@服务器IP`，然后浏览器打开 `localhost:18789` |

---

## 踩坑记录

> 这些都是实际部署中踩过的坑，写在这里省得你再踩一遍。

- OpenClaw Matrix 插件的配置字段叫 `homeserver`，**不是** `homeserverUrl`
- 需要手动装 `@vector-im/matrix-bot-sdk` 到 OpenClaw 的 node_modules（脚本已自动处理）
- 配对必须先在 Element 里发消息触发，再到服务器 approve
- bot 直连 `http://localhost:8008`，不走 nginx，避免 Synapse 重启时 502 错误
- SSL 证书通过 cron 每天凌晨 3 点自动续签，不用管

---

## 安全提醒

- 18789 控制台端口 **永远不要** 暴露到公网
- Gateway Token = 密码，保管好
- 配对完成后 **立即关闭** Matrix 公开注册
- 建议使用 SSH 隧道或 Tailscale 访问控制台

---

## 相关链接

- [OpenClaw 官网](https://openclaw.ai) | [文档](https://docs.openclaw.ai) | [GitHub](https://github.com/openclaw/openclaw)
- [Matrix 协议](https://matrix.org) | [Element Web](https://element.io)
- [ClawHub 技能市场](https://clawhub.ai)

---

<details>
<summary><b>English Summary (click to expand)</b></summary>

### What is this?

A two-script toolkit to deploy [OpenClaw](https://openclaw.ai) (open-source AI agent) + self-hosted Matrix chat on Ubuntu 22.04.

### Quick Start

**Step 1 — Install OpenClaw:**

```bash
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-openclaw.sh | sudo bash
source ~/.bashrc && openclaw onboard --install-daemon
```

**Step 2 — Deploy Matrix (optional):**

```bash
wget https://raw.githubusercontent.com/jiayu505/openclaw/master/setup-matrix-for-openclaw.sh
# Edit domain/email config at top of file
chmod +x setup-matrix-for-openclaw.sh && sudo bash setup-matrix-for-openclaw.sh
```

Then open Element Web, register, invite the bot, send a message, and approve pairing on the server.

For full details, see the Chinese documentation above.

</details>

## License

MIT
