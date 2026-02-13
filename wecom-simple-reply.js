#!/usr/bin/env node
/**
 * 企业微信 Webhook - 简单回复版本
 * 用于测试消息收发，不调用 OpenClaw
 */

const express = require('express');
const crypto = require('crypto');
const https = require('https');

const CONFIG = {
  corpId: process.env.WECOM_CORP_ID,
  agentId: process.env.WECOM_AGENT_ID,
  secret: process.env.WECOM_SECRET,
  token: process.env.WECOM_TOKEN,
  encodingAesKey: process.env.WECOM_AES_KEY,
  port: process.env.PORT || 18790
};

let accessTokenCache = { token: null, expiresAt: 0 };

// 企业微信消息加解密
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

// 获取 Access Token
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
        try {
          const result = JSON.parse(data);
          if (result.access_token) {
            accessTokenCache.token = result.access_token;
            accessTokenCache.expiresAt = now + (result.expires_in - 60) * 1000;
            console.log('[✓] Access token 已获取，有效期', result.expires_in, '秒');
            resolve(result.access_token);
          } else {
            console.error('[✗] 获取 token 失败:', result);
            reject(new Error(result.errmsg));
          }
        } catch (err) {
          reject(err);
        }
      });
    }).on('error', reject);
  });
}

// 发送消息到企业微信
async function sendMessage(toUser, content) {
  try {
    const token = await getAccessToken();
    const msg = {
      touser: toUser,
      msgtype: 'text',
      agentid: parseInt(CONFIG.agentId),
      text: { content }
    };

    return new Promise((resolve, reject) => {
      const postData = JSON.stringify(msg);
      const req = https.request({
        hostname: 'qyapi.weixin.qq.com',
        path: `/cgi-bin/message/send?access_token=${token}`,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData)
        }
      }, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          try {
            const result = JSON.parse(data);
            if (result.errcode === 0) {
              console.log('[✓] 消息已发送给', toUser);
              resolve(result);
            } else {
              console.error('[✗] 发送失败:', result);
              reject(new Error(`${result.errcode}: ${result.errmsg}`));
            }
          } catch (err) {
            reject(err);
          }
        });
      });
      req.on('error', reject);
      req.write(postData);
      req.end();
    });
  } catch (err) {
    console.error('[✗] 发送消息错误:', err.message);
    throw err;
  }
}

// 解析 XML 消息
function parseXml(xml) {
  const extract = (tag) => {
    const m = xml.match(new RegExp(`<${tag}><!\\[CDATA\\[(.+?)\\]\\]></${tag}>`));
    return m ? m[1] : null;
  };
  return {
    fromUser: extract('FromUserName'),
    content: extract('Content'),
    msgType: extract('MsgType')
  };
}

const app = express();
app.use(express.text({ type: 'text/xml' }));

app.get('/health', (req, res) => res.json({ status: 'ok', version: 'simple-reply' }));

// URL 验证
app.get('/webhooks/wecom', (req, res) => {
  const { msg_signature, timestamp, nonce, echostr } = req.query;

  if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, echostr)) {
    console.error('[✗] 签名验证失败');
    return res.status(403).send('Invalid signature');
  }

  const decrypted = wxCrypt.decrypt(echostr);
  console.log('[✓] URL 验证成功');
  res.send(decrypted);
});

// 接收消息
app.post('/webhooks/wecom', async (req, res) => {
  const { msg_signature, timestamp, nonce } = req.query;
  const body = req.body;

  // 提取加密消息
  const encryptMatch = body.match(/<Encrypt><!\[CDATA\[(.*?)\]\]><\/Encrypt>/);
  if (!encryptMatch) {
    console.error('[✗] 消息格式错误');
    return res.status(400).send('Bad format');
  }

  const encrypted = encryptMatch[1];

  // 验证签名
  if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, encrypted)) {
    console.error('[✗] 签名验证失败');
    return res.status(403).send('Invalid signature');
  }

  // 解密消息
  const xml = wxCrypt.decrypt(encrypted);
  const msg = parseXml(xml);

  console.log(`[→] 收到消息 - 用户: ${msg.fromUser}, 内容: "${msg.content}"`);

  // 立即响应企业微信
  res.send('success');

  // 异步发送回复
  if (msg.msgType === 'text' && msg.content) {
    setTimeout(async () => {
      try {
        const reply = `✅ 收到你的消息了！\n\n你说: "${msg.content}"\n\n这是自动回复（简化版本）\n\nOpenClaw 集成开发中...`;

        await sendMessage(msg.fromUser, reply);
        console.log('[✓] 回复已发送');
      } catch (err) {
        console.error('[✗] 回复失败:', err.message);
      }
    }, 200);
  }
});

// 启动服务
app.listen(CONFIG.port, '0.0.0.0', () => {
  console.log(`
╔══════════════════════════════════════════════════════════════╗
║  企业微信 Webhook 服务 - 简单回复版本                         ║
╠══════════════════════════════════════════════════════════════╣
║  监听端口: ${CONFIG.port}                                           ║
║  模式: 简单自动回复（测试用）                                 ║
╚══════════════════════════════════════════════════════════════╝
  `);
});

process.on('SIGTERM', () => {
  console.log('[!] 服务关闭中...');
  process.exit(0);
});
