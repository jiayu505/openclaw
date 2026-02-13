#!/usr/bin/env node
/**
 * 独立的企业微信 Webhook 服务
 * 不依赖 OpenClaw 插件，直接处理企业微信回调
 */

const express = require('express');
const crypto = require('crypto');
const http = require('http');

// 配置（从环境变量或命令行参数读取）
const CONFIG = {
  corpId: process.env.WECOM_CORP_ID || 'ww5a3bb42433abd80c',
  token: process.env.WECOM_TOKEN || 'openclaw2026',
  encodingAesKey: process.env.WECOM_AES_KEY || '67JvBprv0SJmo4Gr5jEkyWSrGcHQsIk4pdkjc00pUe7',
  port: process.env.PORT || 18789,
  openclawApi: process.env.OPENCLAW_API || 'http://127.0.0.1:18789/api'
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
app.post('/webhooks/wecom', (req, res) => {
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

    // TODO: 转发到 OpenClaw API 或处理消息
    // const response = await forwardToOpenClaw(decrypted);

    // 返回成功（企业微信要求返回 "success" 或加密的响应）
    res.type('text/plain').send('success');
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
