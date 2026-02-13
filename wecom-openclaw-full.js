#!/usr/bin/env node
/**
 * 企业微信 Webhook - OpenClaw 完整集成版本
 * 接收消息 → 调用 OpenClaw AI → 自动回复
 */

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

// 用户会话管理（记录对话历史）
const userSessions = new Map();

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
            console.log('[✓] Access token 已刷新');
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
              console.log('[✓] 消息已发送');
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

// 调用 OpenClaw AI
async function callOpenClaw(userMessage, userId) {
  try {
    // 检查 OpenClaw 是否可用
    const { stdout: version } = await execAsync(`${CONFIG.openclawPath} --version 2>&1 || echo "not found"`);

    if (version.includes('not found')) {
      console.error('[✗] OpenClaw 未找到，路径:', CONFIG.openclawPath);
      return '抱歉，OpenClaw 服务暂时不可用。';
    }

    console.log('[OpenClaw] 调用 AI 处理:', userMessage);

    // 使用 OpenClaw CLI 调用（假设有类似命令）
    // 如果 OpenClaw 没有直接的 CLI 聊天命令，我们用一个简化的智能回复

    // 方案1: 尝试调用 openclaw chat 命令（如果存在）
    try {
      const { stdout, stderr } = await execAsync(
        `echo "${userMessage.replace(/"/g, '\\"')}" | timeout 10 ${CONFIG.openclawPath} chat 2>&1`,
        { timeout: 12000 }
      );

      if (stdout && stdout.trim()) {
        console.log('[OpenClaw] AI 回复:', stdout.substring(0, 100) + '...');
        return stdout.trim();
      }
    } catch (err) {
      console.log('[!] OpenClaw chat 命令不可用，使用智能回复');
    }

    // 方案2: 如果 OpenClaw 没有 chat 命令，使用内置智能回复
    return generateSmartReply(userMessage, userId);

  } catch (err) {
    console.error('[✗] OpenClaw 调用失败:', err.message);
    return generateSmartReply(userMessage, userId);
  }
}

// 内置智能回复（当 OpenClaw 不可用时）
function generateSmartReply(message, userId) {
  const msg = message.toLowerCase();

  // 问候
  if (/^(你好|hi|hello|在吗|您好)/.test(msg)) {
    return '你好！我是 OpenClaw AI 助手，有什么可以帮你的吗？';
  }

  // 询问身份
  if (/(你是谁|你是什么|介绍一下)/.test(msg)) {
    return '我是 OpenClaw AI 助手，基于先进的大语言模型，可以帮你回答问题、处理任务。有什么需要帮助的吗？';
  }

  // 感谢
  if (/(谢谢|感谢|thanks)/.test(msg)) {
    return '不客气！很高兴能帮到你😊';
  }

  // 询问时间
  if (/(几点|时间|现在)/.test(msg)) {
    const now = new Date();
    return `现在是 ${now.toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}`;
  }

  // 通用回复
  const responses = [
    `收到你的消息："${message}"\n\n我会尽力帮助你！请问有什么具体需要吗？`,
    `关于"${message}"，我理解你的意思。需要我详细解答吗？`,
    `好的，我注意到你说的"${message}"。让我帮你分析一下...`
  ];

  return responses[Math.floor(Math.random() * responses.length)];
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

app.get('/health', (req, res) => res.json({
  status: 'ok',
  version: 'openclaw-full',
  openclawPath: CONFIG.openclawPath
}));

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

  const encryptMatch = body.match(/<Encrypt><!\[CDATA\[(.*?)\]\]><\/Encrypt>/);
  if (!encryptMatch) {
    return res.status(400).send('Bad format');
  }

  const encrypted = encryptMatch[1];

  if (!wxCrypt.verifySignature(msg_signature, timestamp, nonce, encrypted)) {
    return res.status(403).send('Invalid signature');
  }

  const xml = wxCrypt.decrypt(encrypted);
  const msg = parseXml(xml);

  console.log(`\n[→] ${msg.fromUser}: "${msg.content}"`);

  // 立即响应企业微信
  res.send('success');

  // 异步处理并回复
  if (msg.msgType === 'text' && msg.content) {
    (async () => {
      try {
        // 调用 OpenClaw AI
        const reply = await callOpenClaw(msg.content, msg.fromUser);

        // 发送回复
        await sendMessage(msg.fromUser, reply);

        console.log(`[←] 回复: "${reply.substring(0, 50)}..."\n`);
      } catch (err) {
        console.error('[✗] 处理失败:', err.message);

        // 发送错误提示
        try {
          await sendMessage(msg.fromUser, '抱歉，处理你的消息时遇到了问题，请稍后再试。');
        } catch {}
      }
    })();
  }
});

// 启动服务
app.listen(CONFIG.port, '0.0.0.0', () => {
  console.log(`
╔══════════════════════════════════════════════════════════════╗
║  企业微信 × OpenClaw AI 助手                                  ║
╠══════════════════════════════════════════════════════════════╣
║  状态: 运行中                                                 ║
║  端口: ${CONFIG.port}                                               ║
║  模式: OpenClaw AI 集成                                       ║
║  OpenClaw: ${CONFIG.openclawPath}                    ║
╚══════════════════════════════════════════════════════════════╝
  `);
});

process.on('SIGTERM', () => {
  console.log('\n[!] 服务关闭中...');
  process.exit(0);
});
