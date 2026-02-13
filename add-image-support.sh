#!/bin/bash
# 为企业微信 webhook 添加图片支持（直接调用 Claude API）

echo "添加图片支持..."

# 检查 Anthropic API Key
if [ ! -f ~/.openclaw/config.json ]; then
    echo "⚠ 未找到 OpenClaw 配置"
    exit 1
fi

API_KEY=$(cat ~/.openclaw/config.json | grep -oP '"anthropic":\s*"\K[^"]+' | head -1)

if [ -z "$API_KEY" ]; then
    echo "⚠ 未找到 Anthropic API Key"
    exit 1
fi

echo "✓ 找到 API Key"

# 安装 Anthropic SDK
cd /opt/wecom-webhook
npm install @anthropic-ai/sdk
echo "✓ 已安装 Anthropic SDK"

# 创建支持图片的新服务
cat > /opt/wecom-webhook/server-with-image.js << 'OUTER_EOF'
const express = require('express');
const { getSignature } = require('@wecom/crypto');
const { WXBizMsgCrypt } = require('@wecom/crypto');
const bodyParser = require('body-parser');
const { exec } = require('child_process');
const { promisify } = require('util');
const Anthropic = require('@anthropic-ai/sdk');
const execAsync = promisify(exec);

const app = express();
const PORT = process.env.PORT || 18790;

// 企业微信配置
const CONFIG = {
  corpId: process.env.WECOM_CORP_ID,
  agentId: process.env.WECOM_AGENT_ID,
  secret: process.env.WECOM_SECRET,
  token: process.env.WECOM_TOKEN,
  aesKey: process.env.WECOM_AES_KEY,
  openclawPath: process.env.OPENCLAW_PATH || 'openclaw',
  anthropicKey: process.env.ANTHROPIC_API_KEY
};

// Claude API 客户端
const anthropic = new Anthropic({
  apiKey: CONFIG.anthropicKey
});

const cryptor = new WXBizMsgCrypt(CONFIG.token, CONFIG.aesKey, CONFIG.corpId);

app.use(bodyParser.text({ type: 'text/xml' }));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Access Token 缓存
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

// 下载企业微信图片
async function downloadWeChatImage(mediaId) {
  const token = await getAccessToken();
  const url = `https://qyapi.weixin.qq.com/cgi-bin/media/get?access_token=${token}&media_id=${mediaId}`;

  const response = await fetch(url);
  const buffer = await response.arrayBuffer();
  const base64 = Buffer.from(buffer).toString('base64');

  // 检测图片类型
  const contentType = response.headers.get('content-type') || 'image/jpeg';
  const mediaType = contentType.split('/')[1] || 'jpeg';

  return {
    type: 'image',
    source: {
      type: 'base64',
      media_type: `image/${mediaType}`,
      data: base64
    }
  };
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

// 调用 Claude API（支持图片）
async function callClaudeAPI(messages) {
  try {
    const response = await anthropic.messages.create({
      model: 'claude-opus-4-20250514',
      max_tokens: 4096,
      messages: messages
    });

    const textContent = response.content.find(c => c.type === 'text');
    return textContent ? textContent.text : '抱歉，我无法理解。';
  } catch (error) {
    console.error('[✗] Claude API 错误:', error.message);
    return '抱歉，处理消息时出现错误。';
  }
}

// 调用 OpenClaw（文本消息）
async function callOpenClaw(userMessage, userId) {
  const escapedMessage = userMessage.replace(/"/g, '\\"').replace(/`/g, '\\`');
  const cmd = `${CONFIG.openclawPath} agent --channel wecom --to "${userId}" --message "${escapedMessage}" --json --timeout 60`;

  try {
    const { stdout } = await execAsync(cmd, {
      timeout: 65000,
      maxBuffer: 10485760
    });

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

    const userId = data.xml.FromUserName;
    const msgType = data.xml.MsgType;

    if (msgType === 'text') {
      // 文本消息 - 使用 OpenClaw
      const userMessage = data.xml.Content;
      console.log(`[→] ${userId}: ${userMessage}`);

      const reply = await callOpenClaw(userMessage, userId);
      console.log(`[AI] 回复: ${reply.substring(0, 50)}...`);

      await sendMessage(userId, reply);
      console.log('[✓] 已发送');

    } else if (msgType === 'image') {
      // 图片消息 - 使用 Claude API
      const mediaId = data.xml.MediaId;
      const picUrl = data.xml.PicUrl;

      console.log(`[📷] ${userId}: 发送了图片 (${mediaId})`);

      // 下载图片
      const imageContent = await downloadWeChatImage(mediaId);

      // 构建消息
      const messages = [{
        role: 'user',
        content: [
          imageContent,
          {
            type: 'text',
            text: '请描述这张图片的内容。'
          }
        ]
      }];

      // 调用 Claude API
      const reply = await callClaudeAPI(messages);
      console.log(`[AI] 回复: ${reply.substring(0, 50)}...`);

      await sendMessage(userId, reply);
      console.log('[✓] 已发送');

    } else {
      console.log(`[→] ${userId}: 不支持的消息类型 ${msgType}`);
    }
  } catch (error) {
    console.error('[✗] 处理消息失败:', error);
  }
});

app.listen(PORT, () => {
  console.log(`✓ WeCom × OpenClaw (with image support) :${PORT}`);
});
OUTER_EOF

echo "✓ 已创建支持图片的服务"

# 更新 .env 文件
if ! grep -q "ANTHROPIC_API_KEY" /opt/wecom-webhook/.env; then
    echo "ANTHROPIC_API_KEY=$API_KEY" >> /opt/wecom-webhook/.env
    echo "✓ 已添加 API Key 到配置"
fi

# 更新 systemd 服务
cat > /etc/systemd/system/wecom-webhook.service << 'EOF'
[Unit]
Description=WeCom Webhook Service (with Image Support)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/wecom-webhook
EnvironmentFile=/opt/wecom-webhook/.env
ExecStart=/usr/bin/node /opt/wecom-webhook/server-with-image.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "✓ 已更新 systemd 服务"

# 重启服务
systemctl daemon-reload
systemctl restart wecom-webhook
sleep 3

if systemctl is-active --quiet wecom-webhook; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✓✓✓ 图片支持已启用！ ✓✓✓"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  现在可以："
    echo "  ✅ 发送文本消息（使用 OpenClaw）"
    echo "  ✅ 发送图片消息（使用 Claude API）"
    echo ""
    echo "  去企业微信测试发送图片吧！"
    echo ""
else
    echo "⚠ 服务启动失败，查看日志："
    journalctl -u wecom-webhook -n 30
fi
EOF

echo "✓ 脚本已创建"
echo ""
echo "现在运行："
echo "sudo bash add-image-support.sh"
