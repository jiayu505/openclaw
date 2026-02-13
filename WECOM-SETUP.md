# 企业微信接入 OpenClaw AI 完整教程

> 极简高效的企业微信 AI 助手部署指南，基于 Claude Opus 4

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [详细步骤](#详细步骤)
- [图片支持](#图片支持)
- [常见问题](#常见问题)
- [踩坑记录](#踩坑记录)

---

## 环境要求

- **服务器**: Linux (Ubuntu/Debian)，需要公网 IP
- **域名**: 已配置 SSL 证书（企业微信要求 HTTPS）
- **OpenClaw**: 已安装并配置好 API 密钥
- **Node.js**: v18+ (用于 webhook 服务)
- **Nginx**: 用于反向代理

---

## 快速开始

**一键部署（推荐）：**

```bash
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-wecom-standalone.sh | sudo bash
```

部署完成后，去企业微信后台配置：
1. **URL**: `https://你的域名/webhooks/wecom`
2. **Token**: `openclaw2026`
3. **EncodingAESKey**: `67JvBprv0SJmo4Gr5jEkyWSrGcHQsIk4pdkjc00pUe7`

---

## 详细步骤

### 1. 安装 OpenClaw

```bash
# 下载并运行安装脚本
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-openclaw.sh | sudo bash

# 配置 API 密钥
openclaw config add-key "your-anthropic-api-key"
```

**验证安装：**
```bash
openclaw agent --message "你好" --json
```

### 2. 部署 Webhook 服务

#### 2.1 安装依赖

```bash
# 创建工作目录
mkdir -p /opt/wecom-webhook
cd /opt/wecom-webhook

# 安装 Node.js 依赖
npm init -y
npm install express @wecom/crypto body-parser
```

#### 2.2 创建 Webhook 服务

创建 `/opt/wecom-webhook/server.js`：

```javascript
const express = require('express');
const { getSignature } = require('@wecom/crypto');
const { WXBizMsgCrypt } = require('@wecom/crypto');
const bodyParser = require('body-parser');
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

const app = express();
const PORT = process.env.PORT || 18790;

// 企业微信配置（从环境变量读取）
const CONFIG = {
  corpId: process.env.WECOM_CORP_ID,
  agentId: process.env.WECOM_AGENT_ID,
  secret: process.env.WECOM_SECRET,
  token: process.env.WECOM_TOKEN,
  aesKey: process.env.WECOM_AES_KEY,
  openclawPath: process.env.OPENCLAW_PATH || 'openclaw'
};

// 消息加解密
const cryptor = new WXBizMsgCrypt(CONFIG.token, CONFIG.aesKey, CONFIG.corpId);

app.use(bodyParser.text({ type: 'text/xml' }));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// 获取 Access Token
let cachedToken = null;
let tokenExpireTime = 0;

async function getAccessToken() {
  if (cachedToken && Date.now() < tokenExpireTime) {
    return cachedToken;
  }

  const url = `https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=${CONFIG.corpId}&corpsecret=${CONFIG.secret}`;
  const response = await fetch(url);
  const data = await response.json();

  if (data.errcode === 0) {
    cachedToken = data.access_token;
    tokenExpireTime = Date.now() + (data.expires_in - 300) * 1000;
    return cachedToken;
  }
  throw new Error(`获取 token 失败: ${data.errmsg}`);
}

// 发送消息
async function sendMessage(userId, content) {
  const token = await getAccessToken();
  const url = `https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=${token}`;

  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      touser: userId,
      msgtype: 'text',
      agentid: CONFIG.agentId,
      text: { content }
    })
  });

  const result = await response.json();
  if (result.errcode !== 0) {
    throw new Error(`发送失败: ${result.errmsg}`);
  }
  return result;
}

// 调用 OpenClaw AI
async function callOpenClaw(userMessage, userId) {
  const escapedMessage = userMessage.replace(/"/g, '\\"').replace(/`/g, '\\`');
  const cmd = `${CONFIG.openclawPath} agent --channel wecom --to "${userId}" --message "${escapedMessage}" --json --timeout 30`;

  try {
    const { stdout } = await execAsync(cmd, {
      timeout: 35000,
      maxBuffer: 10485760
    });

    // 使用正则提取 "text": "..." 内容（避免 JSON 解析问题）
    const textMatch = stdout.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/);
    if (textMatch && textMatch[1]) {
      const reply = textMatch[1]
        .replace(/\\n/g, '\n')
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, '\\');
      return reply;
    }

    return '抱歉，我现在无法理解您的问题。';
  } catch (error) {
    console.error('[✗] OpenClaw 错误:', error.message);
    return '抱歉，处理消息时出现错误。';
  }
}

// Webhook 验证（GET）
app.get('/webhooks/wecom', (req, res) => {
  const { msg_signature, timestamp, nonce, echostr } = req.query;

  try {
    const signature = getSignature(CONFIG.token, timestamp, nonce, echostr);
    if (signature === msg_signature) {
      const { message } = cryptor.decrypt(echostr);
      res.send(message);
    } else {
      res.status(403).send('Signature verification failed');
    }
  } catch (error) {
    console.error('[✗] 验证失败:', error);
    res.status(500).send('Error');
  }
});

// 接收消息（POST）
app.post('/webhooks/wecom', async (req, res) => {
  res.send('success');

  try {
    const { msg_signature, timestamp, nonce } = req.query;
    const { message } = cryptor.decrypt(req.body);
    const xml = require('fast-xml-parser');
    const data = xml.parse(message);

    if (data.xml.MsgType === 'text') {
      const userId = data.xml.FromUserName;
      const userMessage = data.xml.Content;

      console.log(`[→] ${userId}: ${userMessage}`);
      console.log(`[AI] ${userId}: ${userMessage}`);

      const reply = await callOpenClaw(userMessage, userId);
      console.log(`[AI] 回复: ${reply.substring(0, 50)}...`);

      await sendMessage(userId, reply);
      console.log('[✓] 已发送');
    }
  } catch (error) {
    console.error('[✗] 处理消息失败:', error);
  }
});

app.listen(PORT, () => {
  console.log(`✓ WeCom × OpenClaw 运行中 :${PORT}`);
});
```

#### 2.3 配置环境变量

创建 `/opt/wecom-webhook/.env`：

```bash
WECOM_CORP_ID=你的企业ID
WECOM_AGENT_ID=你的应用ID
WECOM_SECRET=你的应用Secret
WECOM_TOKEN=openclaw2026
WECOM_AES_KEY=67JvBprv0SJmo4Gr5jEkyWSrGcHQsIk4pdkjc00pUe7
PORT=18790
OPENCLAW_PATH=/usr/local/bin/openclaw
```

**获取企业微信配置：**
- 登录 [企业微信管理后台](https://work.weixin.qq.com/)
- **我的企业** → **企业ID** (CORP_ID)
- **应用管理** → **自建** → 创建应用 → 获取 **AgentId** 和 **Secret**

#### 2.4 创建 Systemd 服务

创建 `/etc/systemd/system/wecom-webhook.service`：

```ini
[Unit]
Description=WeCom Webhook Standalone Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/wecom-webhook
EnvironmentFile=/opt/wecom-webhook/.env
ExecStart=/usr/bin/node /opt/wecom-webhook/server.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**启动服务：**

```bash
systemctl daemon-reload
systemctl enable wecom-webhook
systemctl start wecom-webhook
systemctl status wecom-webhook
```

### 3. 配置 Nginx 反向代理

编辑你的 Nginx 配置文件（例如 `/opt/matrix/nginx/conf.d/matrix.conf`），在 `tslcz.com` 的 server 块中添加：

```nginx
server {
    listen 443 ssl http2;
    server_name tslcz.com;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    # 企业微信 Webhook
    location /webhooks/ {
        proxy_pass http://host.docker.internal:18790/webhooks/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }

    # ... 其他配置
}
```

**重启 Nginx：**

```bash
docker restart matrix-nginx
# 或 nginx -s reload
```

### 4. 企业微信后台配置

1. **应用管理** → **自建** → 你的应用 → **接收消息**
2. 设置 **URL**: `https://你的域名/webhooks/wecom`
3. 设置 **Token**: `openclaw2026`
4. 设置 **EncodingAESKey**: `67JvBprv0SJmo4Gr5jEkyWSrGcHQsIk4pdkjc00pUe7`
5. 点击 **保存**（会自动验证 URL）

### 5. 测试

在企业微信中：
1. 找到你的应用
2. 发送消息："你好"
3. 应该会收到 AI 回复

**查看日志：**
```bash
journalctl -u wecom-webhook -f
```

---

## 图片支持

### 为什么需要图片支持

OpenClaw CLI 目前不支持通过命令行参数传递图片，但 Claude API 支持 vision 功能。为了让企业微信也能发送图片给 AI，我们直接调用 Claude API 处理图片。

### 一键启用图片支持

```bash
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/add-image-with-history.sh | sudo bash
```

**这个脚本会：**
1. ✅ 安装 Anthropic SDK
2. ✅ 添加图片下载和识别功能
3. ✅ **将图片描述保存到 OpenClaw 对话历史**（关键！）
4. ✅ 保留所有现有功能

### 工作原理

```
用户发送图片
    ↓
下载图片 → Claude API 识别
    ↓
将 "[用户发送了图片] 图片内容：..." 发送给 OpenClaw
    ↓
OpenClaw 保存到对话历史
    ↓
发送识别结果给用户
```

**这样做的好处：**
- ✅ 图片能被识别
- ✅ 图片描述保存在对话历史中
- ✅ 后续对话 AI 能看到图片上下文

### 测试图片功能

1. 在企业微信发送一张图片
2. AI 会描述图片内容
3. 问"刚才的图片是什么？"
4. AI 应该能基于历史回答

### 技术细节

**为什么不直接用 OpenClaw？**
- OpenClaw CLI 的 `agent` 命令不支持 `--image` 或 `--file` 参数
- Telegram 等渠道的图片支持是在 Gateway 内部实现的，不经过 CLI

**为什么要保存到历史？**
- 如果只用 Claude API 识别图片但不保存历史，下次对话时 AI 就"忘记"了图片
- 通过将图片描述发送给 OpenClaw，确保对话连贯性

---

## 常见问题

### Q1: URL 验证失败

**原因：**
- Nginx 没有正确代理
- 证书配置错误（企业微信要求 HTTPS）
- Token/AESKey 配置不匹配

**解决：**
```bash
# 检查 Nginx 日志
docker logs matrix-nginx --tail 50

# 检查 webhook 服务
systemctl status wecom-webhook

# 测试 URL 是否可访问
curl https://你的域名/webhooks/wecom
```

### Q2: 发送消息没有回复

**原因：**
- OpenClaw 配置错误
- Webhook 服务未启动
- API 密钥无效

**解决：**
```bash
# 查看 webhook 日志
journalctl -u wecom-webhook -n 50

# 测试 OpenClaw
openclaw agent --message "测试" --json

# 检查 API 密钥
openclaw config list-keys
```

### Q3: 回复内容为空或乱码

**原因：**
- OpenClaw 输出格式变化
- JSON 解析失败

**解决：**
我们使用 **正则表达式提取**而不是 JSON 解析，避免这个问题。如果还有问题，检查 OpenClaw 输出：

```bash
openclaw agent --message "你好" --json
```

### Q4: 群聊消息收不到

**原因：**
- 企业微信的群聊消息需要单独配置
- 应用可见范围未包含群聊成员

**解决：**
1. 检查应用的"可见范围"
2. 在应用配置中查找"群聊使用"或"功能"设置
3. 或创建单独的"群机器人"

---

## 踩坑记录

### 坑1: OpenClaw 插件 webhook 不工作

**问题：** 使用 OpenClaw 的 plugin 系统注册 webhook，但请求无法到达处理函数。

**原因：** Plugin 的 webhookTargets Map 为空，导致请求被路由到默认的 Control UI。

**解决：** 放弃插件，使用**独立的 Node.js webhook 服务**。

---

### 坑2: JSON 解析失败

**问题：** OpenClaw 的 `--json` 输出混有 INFO 日志，导致 JSON 解析失败。

**错误信息：**
```
[INFO] Loading plugins...
{"type":"text","text":"你好"}
```

**尝试的解决方案（失败）：**
```bash
# 尝试用 grep 过滤
openclaw agent --message "你好" --json 2>/dev/null | grep -v "INFO"

# 尝试用 jq 解析
openclaw agent --message "你好" --json | jq -r '.text'
```

**最终解决：** 使用**正则表达式**直接提取 `"text": "..."` 内容：

```javascript
const textMatch = stdout.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/);
```

这比 JSON 解析更可靠！

---

### 坑3: 文件更新不生效

**问题：** 多次用 `curl` 下载更新的脚本，但服务器上运行的还是旧代码。

**原因：**
- GitHub CDN 缓存
- 服务未重启

**解决：**
```bash
# 1. 清除本地缓存
rm -f /tmp/script.sh

# 2. 强制重新下载
curl -fsSL "https://raw.githubusercontent.com/...?t=$(date +%s)" -o script.sh

# 3. 验证文件内容
cat script.sh | head -20

# 4. 重启服务
systemctl restart wecom-webhook
```

---

### 坑4: Nginx 配置被 sed 破坏

**问题：** 使用 `sed` 修改 Nginx 配置文件，导致语法错误，Nginx 进入重启循环。

**错误命令：**
```bash
sed -i '/server_name tslcz.com;/,/^}$/ {
    /location \/webhooks\//a\
    location /openclaw-ai { ... }
}' /opt/matrix/nginx/conf.d/matrix.conf
```

**结果：** 配置文件语法错误，Nginx 无法启动。

**教训：**
1. **永远不要用 sed 修改复杂配置文件**
2. **修改前先备份**：`cp config.conf config.conf.backup`
3. **测试语法**：`nginx -t`（Docker 中：`docker exec nginx nginx -t`）
4. **手动编辑或用完整的 cat 替换**

**正确做法：**
```bash
# 备份
cp matrix.conf matrix.conf.backup

# 用 cat 完整替换
cat > matrix.conf << 'EOF'
# 完整的新配置
...
EOF

# 测试
docker exec matrix-nginx nginx -t

# 重启
docker restart matrix-nginx
```

---

### 坑5: 证书路径错误

**问题：** Nginx 配置中使用 `/etc/letsencrypt/live/...` 证书路径，但容器内找不到。

**错误日志：**
```
nginx: [emerg] cannot load certificate "/etc/letsencrypt/live/tslcz.com/fullchain.pem"
```

**原因：** 证书没有挂载到容器，或挂载路径不同。

**解决：**
```bash
# 1. 检查容器挂载
docker inspect matrix-nginx | grep -A 20 "Mounts"

# 2. 找到实际挂载路径（例如 /etc/nginx/certs）
# 3. 修改配置使用正确路径
ssl_certificate /etc/nginx/certs/fullchain.pem;
ssl_certificate_key /etc/nginx/certs/privkey.pem;
```

---

### 坑6: Element Web 重定向循环

**问题：** 访问 tslcz.com 返回 500 错误：`rewrite or internal redirection cycle`

**错误配置：**
```nginx
root /opt/matrix/element;
location / {
    try_files $uri $uri/ /index.html;
}
```

**原因：** Element 是**容器**，不是静态文件，`/opt/matrix/element` 在 Nginx 容器内不存在。

**解决：** 使用**反向代理**：
```nginx
location / {
    proxy_pass http://element:80;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

---

## 总结

**成功的架构：**
```
企业微信
    ↓ HTTPS
Nginx (反向代理)
    ↓ HTTP
Node.js Webhook 服务 (端口 18790)
    ↓ 命令行
OpenClaw CLI
    ↓ API
Claude Opus 4
```

**核心原则：**
1. ✅ **独立服务** > 插件系统
2. ✅ **正则提取** > JSON 解析
3. ✅ **完整替换** > sed 修改
4. ✅ **反向代理** > 静态文件
5. ✅ **先测试后部署** > 直接上生产

**时间节省：**
- 从 0 到部署成功：~10 小时（含踩坑）
- 使用本教程：**~30 分钟**

---

## 相关链接

- [OpenClaw 官方文档](https://openclaw.ai)
- [企业微信接口文档](https://developer.work.weixin.qq.com/document/)
- [项目 GitHub](https://github.com/jiayu505/openclaw)

---

**更新日期：** 2026-02-13
**作者：** Claude Opus 4.6 × Human
**License：** MIT
