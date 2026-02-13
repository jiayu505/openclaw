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
    console.log(`[OpenClaw] 处理消息 (${userId}):`, userMessage);

    // 转义消息中的特殊字符
    const escapedMessage = userMessage.replace(/"/g, '\\"').replace(/'/g, "'\\''");

    // 调用 OpenClaw agent 命令，过滤日志后用 jq 提取文本
    const cmd = `${CONFIG.openclawPath} agent --channel wecom --to "${userId}" --message "${escapedMessage}" --json --timeout 30 2>&1 | grep -v "INFO\\|WARN\\|ERROR" | grep "^{" | jq -r '.result.payloads[0].text // "抱歉，无法生成回复"'`;

    const { stdout, stderr } = await execAsync(cmd, {
      timeout: 35000,
      maxBuffer: 1024 * 1024 * 10, // 10MB
      shell: '/bin/bash'
    });

    // jq 已经提取了纯文本，直接使用
    const reply = stdout.trim();

    if (reply && reply !== 'null' && !reply.startsWith('{')) {
      console.log('[OpenClaw] ✓ AI 回复:', reply.substring(0, 100) + (reply.length > 100 ? '...' : ''));
      return reply;
    } else {
      console.error('[OpenClaw] 提取失败，原始输出:', stdout);
      return '抱歉，处理消息时出现了问题。';
    }
  } catch (err) {
    console.error('[✗] OpenClaw 调用失败:', err.message);

    // 如果是超时
    if (err.killed || err.message.includes('timeout')) {
      return '抱歉，AI 处理时间过长，请稍后再试。';
    }

    return '抱歉，OpenClaw AI 暂时不可用，请稍后再试。';
  }
}

// 内置智能回复（当 OpenClaw 不可用时）
function generateSmartReply(message, userId) {
  const msg = message.toLowerCase();
  const now = new Date();

  // 问候
  if (/^(你好|hi|hello|在吗|您好|嗨)/.test(msg)) {
    return '你好！我是 OpenClaw AI 助手，有什么可以帮你的吗？';
  }

  // 询问身份
  if (/(你是谁|你是什么|介绍一下|自我介绍)/.test(msg)) {
    return '我是 OpenClaw AI 助手，基于先进的大语言模型，可以帮你回答问题、处理任务、提供建议。有什么需要帮助的吗？';
  }

  // 感谢
  if (/(谢谢|感谢|thanks|thank you)/.test(msg)) {
    return '不客气！很高兴能帮到你 😊';
  }

  // 询问时间
  if (/(几点|什么时间|现在时间)/.test(msg)) {
    return `现在是 ${now.toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false })}`;
  }

  // 询问日期/星期
  if (/(今天|日期|星期几|周几|几号)/.test(msg)) {
    const weekdays = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
    const year = now.getFullYear();
    const month = now.getMonth() + 1;
    const day = now.getDate();
    const weekday = weekdays[now.getDay()];

    return `今天是 ${year}年${month}月${day}日，${weekday}`;
  }

  // 询问天气（提示）
  if (/(天气|温度|下雨)/.test(msg)) {
    return '抱歉，我暂时无法查询实时天气信息。你可以使用天气应用或搜索引擎查看。';
  }

  // 帮助
  if (/(帮助|help|能做什么|功能)/.test(msg)) {
    return `我可以帮你：\n\n✓ 回答问题\n✓ 查询时间日期\n✓ 提供建议\n✓ 聊天交流\n\n有什么需要帮助的吗？`;
  }

  // 通用回复
  return `收到你的问题："${message}"\n\n我正在努力理解并回答。OpenClaw AI 正在持续优化中，如果回答不够准确，请见谅！`;
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
