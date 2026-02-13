#!/usr/bin/env node
const express = require('express');
const crypto = require('crypto');
const https = require('https');
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

const CONFIG = {
  corpId: process.env.WECOM_CORP_ID,
  agentId: process.env.WECOM_AGENT_ID,
  secret: process.env.WECOM_SECRET,
  token: process.env.WECOM_TOKEN,
  encodingAesKey: process.env.WECOM_AES_KEY,
  port: process.env.PORT || 18790,
  openclawPath: process.env.OPENCLAW_PATH || '/root/.npm-global/bin/openclaw'
};

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

async function callOpenClaw(userMessage, userId) {
  try {
    console.log(`[AI] ${userId}: ${userMessage}`);
    const escapedMessage = userMessage.replace(/"/g, '\\"').replace(/'/g, "'\\''");
    const cmd = `${CONFIG.openclawPath} agent --channel wecom --to "${userId}" --message "${escapedMessage}" --json --timeout 30`;

    const { stdout } = await execAsync(cmd, { timeout: 35000, maxBuffer: 10485760 });

    // 用正则提取 "text": "..." 内容（支持转义字符）
    const textMatch = stdout.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/);

    if (textMatch && textMatch[1]) {
      // 处理 JSON 转义字符
      const reply = textMatch[1]
        .replace(/\\n/g, '\n')
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, '\\');

      console.log(`[AI] 回复: ${reply.substring(0, 80)}...`);
      return reply;
    }

    console.error('[✗] 未找到文本，输出:', stdout.substring(0, 200));
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
  return { fromUser: extract('FromUserName'), content: extract('Content'), msgType: extract('MsgType') };
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
  console.log(`[→] ${msg.fromUser}: ${msg.content}`);

  res.send('success');

  if (msg.msgType === 'text') {
    (async () => {
      try {
        const reply = await callOpenClaw(msg.content, msg.fromUser);
        await sendMessage(msg.fromUser, reply);
      } catch {}
    })();
  }
});

app.listen(CONFIG.port, '0.0.0.0', () => {
  console.log(`\n✓ WeCom × OpenClaw 运行中 :${CONFIG.port}\n`);
});
