#!/bin/bash
# 直接修改现有服务，添加图片支持（原生方式）

echo "启用图片支持（修改现有服务）..."

# 1. 自动获取 API Key（从 OpenClaw 运行时环境）
echo ""
echo "检测 API Key..."

# 尝试从 OpenClaw 命令获取
API_KEY=$(openclaw agent --message "test" --json 2>&1 | grep -oP 'x-api-key.*?sk-ant-[a-zA-Z0-9_-]+' | head -1 | grep -oP 'sk-ant-[a-zA-Z0-9_-]+' || true)

if [ -z "$API_KEY" ]; then
    # 尝试从环境变量获取
    API_KEY="${ANTHROPIC_API_KEY:-}"
fi

if [ -z "$API_KEY" ]; then
    echo "⚠ 无法自动检测 API Key"
    echo "请输入你的 Anthropic API Key:"
    read -p "API Key: " API_KEY
fi

if [ -z "$API_KEY" ]; then
    echo "✗ API Key 不能为空"
    exit 1
fi

echo "✓ API Key: ${API_KEY:0:20}...${API_KEY: -4}"

# 2. 安装依赖
echo ""
echo "安装 Anthropic SDK..."
cd /opt/wecom-webhook
npm install @anthropic-ai/sdk fast-xml-parser
echo "✓ 依赖已安装"

# 3. 备份现有服务
cp /opt/wecom-webhook/server.js /opt/wecom-webhook/server.js.backup-$(date +%s)
echo "✓ 已备份原服务"

# 4. 修改服务（直接覆盖）
echo ""
echo "更新服务代码..."
cat > /opt/wecom-webhook/server.js << 'EOF'
const express = require('express');
const { getSignature } = require('@wecom/crypto');
const { WXBizMsgCrypt } = require('@wecom/crypto');
const bodyParser = require('body-parser');
const { exec } = require('child_process');
const { promisify } = require('util');
const Anthropic = require('@anthropic-ai/sdk');
const xml = require('fast-xml-parser');
const execAsync = promisify(exec);

const app = express();
const PORT = process.env.PORT || 18790;

// 配置
const CONFIG = {
  corpId: process.env.WECOM_CORP_ID,
  agentId: process.env.WECOM_AGENT_ID,
  secret: process.env.WECOM_SECRET,
  token: process.env.WECOM_TOKEN,
  aesKey: process.env.WECOM_AES_KEY,
  openclawPath: process.env.OPENCLAW_PATH || 'openclaw',
  anthropicKey: process.env.ANTHROPIC_API_KEY
};

const anthropic = new Anthropic({ apiKey: CONFIG.anthropicKey });
const cryptor = new WXBizMsgCrypt(CONFIG.token, CONFIG.aesKey, CONFIG.corpId);

app.use(bodyParser.text({ type: 'text/xml' }));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

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

async function downloadImage(mediaId) {
  const token = await getAccessToken();
  const url = `https://qyapi.weixin.qq.com/cgi-bin/media/get?access_token=${token}&media_id=${mediaId}`;
  const response = await fetch(url);
  const buffer = await response.arrayBuffer();
  const base64 = Buffer.from(buffer).toString('base64');
  const contentType = response.headers.get('content-type') || 'image/jpeg';
  const mediaType = contentType.split('/')[1] || 'jpeg';
  return {
    type: 'image',
    source: { type: 'base64', media_type: `image/${mediaType}`, data: base64 }
  };
}

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
  if (result.errcode !== 0) throw new Error(`发送失败: ${result.errmsg}`);
  return result;
}

async function callClaude(messages) {
  try {
    const response = await anthropic.messages.create({
      model: 'claude-opus-4-20250514',
      max_tokens: 4096,
      messages: messages
    });
    const textContent = response.content.find(c => c.type === 'text');
    return textContent ? textContent.text : '抱歉，我无法理解。';
  } catch (error) {
    console.error('[✗] Claude 错误:', error.message);
    return '抱歉，处理时出现错误。';
  }
}

async function callOpenClaw(userMessage, userId) {
  const escapedMessage = userMessage.replace(/"/g, '\\"').replace(/`/g, '\\`');
  const cmd = `${CONFIG.openclawPath} agent --channel wecom --to "${userId}" --message "${escapedMessage}" --json --timeout 60`;
  try {
    const { stdout } = await execAsync(cmd, { timeout: 65000, maxBuffer: 10485760 });
    const textMatch = stdout.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/);
    if (textMatch && textMatch[1]) {
      return textMatch[1].replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    return '抱歉，我现在无法理解您的问题。';
  } catch (error) {
    console.error('[✗] OpenClaw 错误:', error.message);
    return '抱歉，处理消息时出现错误。';
  }
}

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

app.post('/webhooks/wecom', async (req, res) => {
  res.send('success');
  try {
    const { message } = cryptor.decrypt(req.body);
    const data = xml.parse(message);
    const userId = data.xml.FromUserName;
    const msgType = data.xml.MsgType;

    if (msgType === 'text') {
      const userMessage = data.xml.Content;
      console.log(`[→] ${userId}: ${userMessage}`);
      const reply = await callOpenClaw(userMessage, userId);
      console.log(`[AI] ${reply.substring(0, 50)}...`);
      await sendMessage(userId, reply);
      console.log('[✓] 已发送');

    } else if (msgType === 'image') {
      const mediaId = data.xml.MediaId;
      console.log(`[📷] ${userId}: 图片 ${mediaId}`);
      const imageContent = await downloadImage(mediaId);
      const messages = [{
        role: 'user',
        content: [imageContent, { type: 'text', text: '请详细描述这张图片。' }]
      }];
      const reply = await callClaude(messages);
      console.log(`[AI] ${reply.substring(0, 50)}...`);
      await sendMessage(userId, reply);
      console.log('[✓] 已发送');

    } else {
      console.log(`[→] ${userId}: 不支持的类型 ${msgType}`);
    }
  } catch (error) {
    console.error('[✗] 处理失败:', error);
  }
});

app.listen(PORT, () => {
  console.log(`✓ WeCom Webhook (图片支持) :${PORT}`);
});
EOF

echo "✓ 服务代码已更新"

# 5. 更新环境变量
if ! grep -q "ANTHROPIC_API_KEY" /opt/wecom-webhook/.env; then
    echo "ANTHROPIC_API_KEY=$API_KEY" >> /opt/wecom-webhook/.env
    echo "✓ 已添加 API Key"
else
    sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$API_KEY|" /opt/wecom-webhook/.env
    echo "✓ 已更新 API Key"
fi

# 6. 重启服务
echo ""
echo "重启服务..."
systemctl restart wecom-webhook
sleep 3

if systemctl is-active --quiet wecom-webhook; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✓✓✓ 图片支持已启用！ ✓✓✓"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  ✅ 文本消息 → OpenClaw（有对话历史）"
    echo "  ✅ 图片消息 → Claude API（识别图片）"
    echo ""
    echo "  测试：去企业微信发送图片！"
    echo ""
else
    echo "⚠ 服务启动失败"
    journalctl -u wecom-webhook -n 30
fi
