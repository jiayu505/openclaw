#!/bin/bash
# 为企业微信添加图片支持（保存到对话历史）

echo "为企业微信添加图片支持（含历史记录）..."

cd /opt/wecom-webhook

# 安装依赖
echo "安装 Anthropic SDK..."
npm install @anthropic-ai/sdk
echo "✓ 依赖已安装"

# 备份
cp server.js server.js.before-image-history
echo "✓ 已备份"

# 创建改进版
cat > server.js << 'EOF'
#!/usr/bin/env node
const express = require('express');
const crypto = require('crypto');
const https = require('https');
const { exec } = require('child_process');
const { promisify } = require('util');
const Anthropic = require('@anthropic-ai/sdk');
const execAsync = promisify(exec);

const CONFIG = {
  corpId: process.env.WECOM_CORP_ID,
  agentId: process.env.WECOM_AGENT_ID,
  secret: process.env.WECOM_SECRET,
  token: process.env.WECOM_TOKEN,
  encodingAesKey: process.env.WECOM_AES_KEY,
  port: process.env.PORT || 18790,
  openclawPath: process.env.OPENCLAW_PATH || '/root/.npm-global/bin/openclaw',
  anthropicKey: process.env.ANTHROPIC_API_KEY
};

const anthropic = new Anthropic({ apiKey: CONFIG.anthropicKey });
let accessTokenCache = { token: null, expiresAt: 0 };

class WXBizMsgCrypt {
  constructor(token, encodingAesKey, corpId) {
    this.token = token;
    this.corpId = corpId;
    const aesKey = Buffer.from(encodingAesKey + '=', 'base64');
    this.key = aesKey;
    this.iv = aesKey.slice(0, 16);
  }
  verifySignature(signature, timestamp, nonce, echostr) {
    const arr = [this.token, timestamp, nonce, echostr].sort();
    const sha1 = crypto.createHash('sha1').update(arr.join('')).digest('hex');
    return sha1 === signature;
  }
  decrypt(encrypted) {
    const decipher = crypto.createDecipheriv('aes-256-cbc', this.key, this.iv);
    decipher.setAutoPadding(false);
    let decrypted = Buffer.concat([decipher.update(encrypted, 'base64'), decipher.final()]);
    const pad = decrypted[decrypted.length - 1];
    decrypted = decrypted.slice(0, decrypted.length - pad);
    const content = decrypted.slice(16);
    const msgLen = content.readUInt32BE(0);
    const msg = content.slice(4, msgLen + 4).toString('utf8');
    return msg;
  }
}

const wxCrypt = new WXBizMsgCrypt(CONFIG.token, CONFIG.encodingAesKey, CONFIG.corpId);

async function getAccessToken() {
  const now = Date.now();
  if (accessTokenCache.token && now < accessTokenCache.expiresAt) {
    return accessTokenCache.token;
  }
  return new Promise((resolve, reject) => {
    const url = `https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=${CONFIG.corpId}&corpsecret=${CONFIG.secret}`;
    https.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        const result = JSON.parse(data);
        if (result.access_token) {
          accessTokenCache.token = result.access_token;
          accessTokenCache.expiresAt = now + (result.expires_in - 60) * 1000;
          console.log('[✓] Token OK');
          resolve(result.access_token);
        } else {
          reject(new Error(result.errmsg));
        }
      });
    }).on('error', reject);
  });
}

async function downloadImage(mediaId) {
  const token = await getAccessToken();
  return new Promise((resolve, reject) => {
    const url = `https://qyapi.weixin.qq.com/cgi-bin/media/get?access_token=${token}&media_id=${mediaId}`;
    https.get(url, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const buffer = Buffer.concat(chunks);
        const base64 = buffer.toString('base64');
        const contentType = res.headers['content-type'] || 'image/jpeg';
        const mediaType = contentType.split('/')[1] || 'jpeg';
        resolve({
          type: 'image',
          source: { type: 'base64', media_type: `image/${mediaType}`, data: base64 }
        });
      });
    }).on('error', reject);
  });
}

async function sendMessage(toUser, content) {
  const token = await getAccessToken();
  const msg = { touser: toUser, msgtype: 'text', agentid: parseInt(CONFIG.agentId), text: { content } };
  return new Promise((resolve, reject) => {
    const postData = JSON.stringify(msg);
    const req = https.request({
      hostname: 'qyapi.weixin.qq.com',
      path: `/cgi-bin/message/send?access_token=${token}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) }
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        const result = JSON.parse(data);
        if (result.errcode === 0) {
          console.log('[✓] 已发送');
          resolve(result);
        } else {
          reject(new Error(`${result.errcode}: ${result.errmsg}`));
        }
      });
    });
    req.on('error', reject);
    req.write(postData);
    req.end();
  });
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
    console.error('[✗] Claude:', error.message);
    return '抱歉，处理时出现错误。';
  }
}

async function callOpenClaw(userMessage, userId) {
  try {
    console.log(`[AI] ${userId}: ${userMessage}`);
    const escapedMessage = userMessage.replace(/"/g, '\\"').replace(/'/g, "'\\''");
    const cmd = `${CONFIG.openclawPath} agent --channel wecom --to "${userId}" --message "${escapedMessage}" --json --timeout 60`;

    const { stdout } = await execAsync(cmd, { timeout: 65000, maxBuffer: 10485760 });
    const textMatch = stdout.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/);

    if (textMatch && textMatch[1]) {
      const reply = textMatch[1]
        .replace(/\\n/g, '\n')
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, '\\');
      console.log(`[AI] 回复: ${reply.substring(0, 80)}...`);
      return reply;
    }

    console.error('[✗] 未找到文本');
    return '抱歉，AI 未返回有效回复';
  } catch (err) {
    console.error('[✗]', err.message);
    return err.killed ? 'AI 处理超时，请稍后再试' : 'AI 暂时不可用';
  }
}

function parseXml(xml) {
  const extract = (tag) => {
    const m = xml.match(new RegExp(`<${tag}><!\\[CDATA\\[(.+?)\\]\\]></${tag}>`));
    return m ? m[1] : null;
  };
  return {
    fromUser: extract('FromUserName'),
    content: extract('Content'),
    msgType: extract('MsgType'),
    mediaId: extract('MediaId'),
    picUrl: extract('PicUrl')
  };
}

const app = express();
app.use(express.text({ type: 'text/xml' }));
app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.get('/webhooks/wecom', (req, res) => {
  const { msg_signature, timestamp, nonce, echostr } = req.query;
  if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, echostr)) {
    return res.status(403).send('Invalid');
  }
  res.send(wxCrypt.decrypt(echostr));
});

app.post('/webhooks/wecom', async (req, res) => {
  const { msg_signature, timestamp, nonce } = req.query;
  const encryptMatch = req.body.match(/<Encrypt><!\[CDATA\[(.*?)\]\]><\/Encrypt>/);
  if (!encryptMatch) return res.status(400).send('Bad');

  const encrypted = encryptMatch[1];
  if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, encrypted)) {
    return res.status(403).send('Invalid');
  }

  const xml = wxCrypt.decrypt(encrypted);
  const msg = parseXml(xml);

  res.send('success');

  if (msg.msgType === 'text') {
    console.log(`[→] ${msg.fromUser}: ${msg.content}`);
    (async () => {
      try {
        const reply = await callOpenClaw(msg.content, msg.fromUser);
        await sendMessage(msg.fromUser, reply);
      } catch (err) {
        console.error('[✗] 处理失败:', err.message);
      }
    })();

  } else if (msg.msgType === 'image') {
    console.log(`[📷] ${msg.fromUser}: 图片 ${msg.mediaId}`);
    (async () => {
      try {
        // 1. 用 Claude 识别图片
        const imageContent = await downloadImage(msg.mediaId);
        const claudeMessages = [{
          role: 'user',
          content: [imageContent, { type: 'text', text: '请详细描述这张图片的内容。' }]
        }];
        const imageDescription = await callClaude(claudeMessages);
        console.log(`[AI] 图片描述: ${imageDescription.substring(0, 50)}...`);

        // 2. 将图片描述保存到 OpenClaw 历史
        const historyMessage = `[用户发送了图片]\n\n图片内容：${imageDescription}`;
        await callOpenClaw(historyMessage, msg.fromUser);
        console.log('[✓] 已保存到历史');

        // 3. 发送识别结果给用户
        await sendMessage(msg.fromUser, imageDescription);

      } catch (err) {
        console.error('[✗] 处理图片失败:', err.message);
        await sendMessage(msg.fromUser, '抱歉，处理图片时出现错误。');
      }
    })();

  } else {
    console.log(`[→] ${msg.fromUser}: 不支持 ${msg.msgType}`);
  }
});

app.listen(CONFIG.port, () => {
  console.log(`✓ WeCom × OpenClaw (图片+历史) :${CONFIG.port}`);
});
EOF

echo "✓ 代码已更新"

# 重启
systemctl restart wecom-webhook
sleep 3

if systemctl is-active --quiet wecom-webhook; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✓✓✓ 图片支持已启用（含历史记录）！ ✓✓✓"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  工作流程："
    echo "  1️⃣  用户发送图片"
    echo "  2️⃣  Claude 识别图片内容"
    echo "  3️⃣  将图片描述保存到 OpenClaw 历史"
    echo "  4️⃣  发送识别结果给用户"
    echo ""
    echo "  现在图片也有上下文了！"
    echo ""
    echo "  去企业微信测试：发图片后再问相关问题！"
    echo ""
else
    echo "⚠ 启动失败"
    journalctl -u wecom-webhook -n 30
fi
