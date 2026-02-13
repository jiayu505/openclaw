#!/usr/bin/env node
/**
 * 独立的企业微信 Webhook 服务
 * 不依赖 OpenClaw 插件，直接处理企业微信回调
 */

const express = require('express');
const crypto = require('crypto');
const http = require('http');
const https = require('https');

// 配置（从环境变量或命令行参数读取）
const CONFIG = {
  corpId: process.env.WECOM_CORP_ID || 'ww5a3bb42433abd80c',
  agentId: process.env.WECOM_AGENT_ID || '1000002',
  secret: process.env.WECOM_SECRET || 'rL5tdzpErGE0z7kq6q_Vpn_VGv2u6jej1urI3F-OyDU',
  token: process.env.WECOM_TOKEN || 'openclaw2026',
  encodingAesKey: process.env.WECOM_AES_KEY || '67JvBprv0SJmo4Gr5jEkyWSrGcHQsIk4pdkjc00pUe7',
  port: process.env.PORT || 18789,
  openclawApi: process.env.OPENCLAW_API || 'http://127.0.0.1:18789'
};

// Access Token 缓存
let accessTokenCache = {
  token: null,
  expiresAt: 0
};

// 企业微信消息加解密类
class WXBizMsgCrypt {
  constructor(token, encodingAesKey, corpId) {
    this.token = token;
    this.corpId = corpId;

    // AES Key 解码
    const aesKey = Buffer.from(encodingAesKey + '=', 'base64');
    this.key = aesKey;
    this.iv = aesKey.slice(0, 16);
  }

  // 验证签名
  verifySignature(signature, timestamp, nonce, echostr) {
    const arr = [this.token, timestamp, nonce, echostr].sort();
    const str = arr.join('');
    const sha1 = crypto.createHash('sha1').update(str).digest('hex');
    return sha1 === signature;
  }

  // 解密消息
  decrypt(encrypted) {
    const decipher = crypto.createDecipheriv('aes-256-cbc', this.key, this.iv);
    decipher.setAutoPadding(false);

    let decrypted = Buffer.concat([
      decipher.update(encrypted, 'base64'),
      decipher.final()
    ]);

    // 去除padding
    const pad = decrypted[decrypted.length - 1];
    decrypted = decrypted.slice(0, decrypted.length - pad);

    // 解析内容: 16字节随机字符串 + 4字节消息长度 + 消息内容 + corpId
    const content = decrypted.slice(16);
    const msgLen = content.readUInt32BE(0);
    const msg = content.slice(4, msgLen + 4).toString('utf8');
    const fromCorpId = content.slice(msgLen + 4).toString('utf8');

    if (fromCorpId !== this.corpId) {
      throw new Error('CorpId mismatch');
    }

    return msg;
  }

  // 加密消息
  encrypt(text) {
    const random = crypto.randomBytes(16);
    const msgLen = Buffer.alloc(4);
    msgLen.writeUInt32BE(Buffer.byteLength(text), 0);

    const raw = Buffer.concat([
      random,
      msgLen,
      Buffer.from(text),
      Buffer.from(this.corpId)
    ]);

    // PKCS7 padding
    const blockSize = 32;
    const padLen = blockSize - (raw.length % blockSize);
    const padding = Buffer.alloc(padLen, padLen);
    const padded = Buffer.concat([raw, padding]);

    const cipher = crypto.createCipheriv('aes-256-cbc', this.key, this.iv);
    cipher.setAutoPadding(false);

    const encrypted = Buffer.concat([
      cipher.update(padded),
      cipher.final()
    ]);

    return encrypted.toString('base64');
  }

  // 生成签名
  genSignature(timestamp, nonce, encrypted) {
    const arr = [this.token, timestamp, nonce, encrypted].sort();
    const str = arr.join('');
    return crypto.createHash('sha1').update(str).digest('hex');
  }
}

// 创建加解密实例
const wxCrypt = new WXBizMsgCrypt(CONFIG.token, CONFIG.encodingAesKey, CONFIG.corpId);

// 获取企业微信 Access Token
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
            console.log('[WeCom] Access token refreshed, expires in', result.expires_in, 'seconds');
            resolve(result.access_token);
          } else {
            console.error('[WeCom] Failed to get access token:', result);
            reject(new Error(result.errmsg || 'Failed to get access token'));
          }
        } catch (err) {
          reject(err);
        }
      });
    }).on('error', reject);
  });
}

// 发送消息到企业微信
async function sendWeComMessage(toUser, content) {
  try {
    const accessToken = await getAccessToken();
    const message = {
      touser: toUser,
      msgtype: 'text',
      agentid: parseInt(CONFIG.agentId),
      text: {
        content: content
      }
    };

    return new Promise((resolve, reject) => {
      const postData = JSON.stringify(message);
      const options = {
        hostname: 'qyapi.weixin.qq.com',
        path: `/cgi-bin/message/send?access_token=${accessToken}`,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData)
        }
      };

      const req = https.request(options, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          try {
            const result = JSON.parse(data);
            if (result.errcode === 0) {
              console.log('[WeCom] ✓ Message sent to', toUser);
              resolve(result);
            } else {
              console.error('[WeCom] Failed to send message:', result);
              reject(new Error(result.errmsg));
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
    console.error('[WeCom] Send message error:', err.message);
    throw err;
  }
}

// 调用 OpenClaw API
async function callOpenClaw(userMessage, userId) {
  return new Promise((resolve, reject) => {
    const postData = JSON.stringify({
      message: userMessage,
      userId: userId,
      channel: 'wecom'
    });

    const options = {
      hostname: '127.0.0.1',
      port: 18789,
      path: '/api/chat',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          const result = JSON.parse(data);
          console.log('[OpenClaw] Response:', result);
          resolve(result.reply || result.message || '收到你的消息了！');
        } catch (err) {
          console.error('[OpenClaw] Failed to parse response:', data);
          resolve('抱歉，处理消息时出现了问题。');
        }
      });
    });

    req.on('error', (err) => {
      console.error('[OpenClaw] API error:', err.message);
      resolve('OpenClaw 服务暂时不可用，请稍后再试。');
    });

    req.write(postData);
    req.end();
  });
}

// 解析 XML 消息
function parseXmlMessage(xml) {
  const extract = (tag) => {
    const match = xml.match(new RegExp(`<${tag}><!\\[CDATA\\[(.+?)\\]\\]></${tag}>`));
    return match ? match[1] : null;
  };
  const extractNum = (tag) => {
    const match = xml.match(new RegExp(`<${tag}>(\\d+)</${tag}>`));
    return match ? match[1] : null;
  };

  return {
    toUser: extract('ToUserName'),
    fromUser: extract('FromUserName'),
    createTime: extractNum('CreateTime'),
    msgType: extract('MsgType'),
    content: extract('Content'),
    msgId: extractNum('MsgId'),
    agentId: extractNum('AgentID')
  };
}

// 创建 Express 应用
const app = express();
app.use(express.text({ type: 'text/xml' }));
app.use(express.json());

// 健康检查
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'wecom-webhook', version: '1.0.0' });
});

// WeCom Webhook 处理（GET - URL验证）
app.get('/webhooks/wecom', (req, res) => {
  const { msg_signature, timestamp, nonce, echostr } = req.query;

  console.log('[WeCom] URL Verification:', {
    msg_signature,
    timestamp,
    nonce,
    echostr: echostr ? echostr.substring(0, 20) + '...' : undefined
  });

  if (!msg_signature || !timestamp || !nonce || !echostr) {
    console.error('[WeCom] Missing parameters');
    return res.status(400).send('Missing parameters');
  }

  try {
    // 验证签名
    if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, echostr)) {
      console.error('[WeCom] Signature verification failed');
      return res.status(403).send('Signature verification failed');
    }

    // 解密 echostr
    const decrypted = wxCrypt.decrypt(echostr);
    console.log('[WeCom] ✓ Verification successful, returning:', decrypted);

    res.type('text/plain').send(decrypted);
  } catch (err) {
    console.error('[WeCom] Decryption error:', err.message);
    res.status(500).send('Decryption error');
  }
});

// WeCom Webhook 处理（POST - 接收消息）
app.post('/webhooks/wecom', async (req, res) => {
  const { msg_signature, timestamp, nonce } = req.query;
  const body = req.body;

  console.log('[WeCom] Message received:', {
    msg_signature,
    timestamp,
    nonce,
    bodyLength: body ? body.length : 0
  });

  if (!msg_signature || !timestamp || !nonce) {
    return res.status(400).send('Missing parameters');
  }

  try {
    // 解析 XML，提取加密消息
    const encryptMatch = body.match(/<Encrypt><!\[CDATA\[(.*?)\]\]><\/Encrypt>/);
    if (!encryptMatch) {
      console.error('[WeCom] Cannot find <Encrypt> in body');
      return res.status(400).send('Invalid message format');
    }

    const encrypted = encryptMatch[1];

    // 验证签名
    if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, encrypted)) {
      console.error('[WeCom] Signature verification failed');
      return res.status(403).send('Signature verification failed');
    }

    // 解密消息
    const decrypted = wxCrypt.decrypt(encrypted);
    console.log('[WeCom] Decrypted message:', decrypted);

    // 解析消息内容
    const msg = parseXmlMessage(decrypted);
    console.log('[WeCom] Parsed:', {
      from: msg.fromUser,
      type: msg.msgType,
      content: msg.content
    });

    // 先返回成功（企业微信要求5秒内响应）
    res.type('text/plain').send('success');

    // 异步处理消息（不阻塞响应）
    if (msg.msgType === 'text' && msg.content) {
      (async () => {
        try {
          console.log('[OpenClaw] Forwarding to OpenClaw:', msg.content);

          // 调用 OpenClaw API
          const reply = await callOpenClaw(msg.content, msg.fromUser);

          // 发送回复到企业微信
          await sendWeComMessage(msg.fromUser, reply);

          console.log('[WeCom] ✓ Reply sent:', reply.substring(0, 50) + '...');
        } catch (err) {
          console.error('[WeCom] Failed to process message:', err.message);
        }
      })();
    }
  } catch (err) {
    console.error('[WeCom] Message processing error:', err.message);
    res.status(500).send('Processing error');
  }
});

// 启动服务
const server = app.listen(CONFIG.port, '0.0.0.0', () => {
  console.log(`
╔══════════════════════════════════════════════════════════════╗
║  企业微信 Webhook 独立服务已启动                              ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  监听地址: 0.0.0.0:${CONFIG.port}                                 ║
║  Webhook 路径: /webhooks/wecom                               ║
║  健康检查: /health                                            ║
║                                                              ║
║  配置:                                                        ║
║    CorpId: ${CONFIG.corpId}                     ║
║    Token: ${CONFIG.token}                                   ║
║                                                              ║
║  去企业微信后台填写:                                          ║
║    URL: https://tslcz.com/webhooks/wecom                     ║
║    Token: ${CONFIG.token}                                   ║
║    EncodingAESKey: ${CONFIG.encodingAesKey}    ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
  `);
});

// 优雅关闭
process.on('SIGTERM', () => {
  console.log('[WeCom] Shutting down gracefully...');
  server.close(() => {
    console.log('[WeCom] Server closed');
    process.exit(0);
  });
});
