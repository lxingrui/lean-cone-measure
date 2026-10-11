// 把运行状态推到飞书/企业微信自定义机器人 webhook。
//
// 为什么单独一个文件：run.sh 里塞 JSON 转义很容易写错（中文 + 换行 + 引号）。
//
// ⚠️ webhook URL 与签名密钥都是凭证，只从环境变量读：
//      FEISHU_WEBHOOK      （飞书自定义机器人 webhook）
//      FEISHU_SECRET       （飞书「签名校验」密钥；机器人开了签名校验时必填，否则报 19021）
//      WEBHOOK_URL         （通用别名；企业微信也用这个）
//    没有设置时静默跳过，不影响主流程。
//
// 飞书签名算法（官方）：
//   stringToSign = `${timestamp}\n${secret}`
//   sign         = base64( HMAC-SHA256(key = stringToSign, data = "") )
//
// 用法:
//   node notify.mjs ok|fail|start "标题" "正文（可含换行）" [详情文件]
//   或读环境变量 NOTIFY_STATUS / NOTIFY_TITLE / NOTIFY_BODY

import fs from 'node:fs';
import crypto from 'node:crypto';

const STATUS = process.argv[2] || process.env.NOTIFY_STATUS || 'info';
const TITLE = process.argv[3] || process.env.NOTIFY_TITLE || 'lean-cone-measure';
let BODY = process.argv[4] || process.env.NOTIFY_BODY || '';
const DETAIL_FILE = process.argv[5] || '';

const URL = process.env.FEISHU_WEBHOOK || process.env.WEBHOOK_URL || '';
if (!URL) { console.error('[notify] 未配置 FEISHU_WEBHOOK / WEBHOOK_URL，跳过'); process.exit(0); }
const SECRET = process.env.FEISHU_SECRET || '';

// 飞书签名：开了「签名校验」的机器人必须带 timestamp + sign
function signPayload() {
  if (!SECRET) return {};
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sign = crypto.createHmac('sha256', `${timestamp}\n${SECRET}`).update('').digest('base64');
  return { timestamp, sign };
}

// 详情文件（例如 summary.json）里挑几行关键信息塞进正文
if (DETAIL_FILE && fs.existsSync(DETAIL_FILE)) {
  try {
    const raw = fs.readFileSync(DETAIL_FILE, 'utf8');
    let extra = '';
    if (DETAIL_FILE.endsWith('.json')) {
      const o = JSON.parse(raw);
      const lines = [];
      const pick = (label, v) => { if (v !== undefined && v !== null) lines.push(`${label}: ${v}`); };
      pick('声明数', o.declarations);
      pick('带权边', o.weightedEdges);
      if (o.depth) pick('depth 中位/最大', `${o.depth.median} / ${o.depth.max}`);
      if (o.log2Unwrapped) pick('log2U 中位/最大', `${o.log2Unwrapped.median} / ${o.log2Unwrapped.max}`);
      if (o.fit) {
        pick('斜率 (bit/层)', o.fit.slope_bits_per_level);
        pick('r', o.fit.r);
        pick('3σ', o.fit.three_sigma);
      }
      if (o.outliers) pick('离群 上/下', `${o.outliers.above_3sigma} / ${o.outliers.below_3sigma}`);
      extra = lines.join('\n');
    } else {
      extra = raw.split('\n').slice(-25).join('\n');   // 日志尾部
    }
    if (extra) BODY = (BODY ? BODY + '\n' : '') + extra;
  } catch (e) { /* 详情读不到就算了，不阻塞通知 */ }
}

const ICON = { ok: '✅', fail: '❌', start: '🚀', warn: '⚠️' }[STATUS] || 'ℹ️';

// 飞书自定义机器人文本消息有长度限制，截断保护
const MAX = 3500;
let text = `${ICON} ${TITLE}\n${BODY}`;
if (text.length > MAX) text = text.slice(0, MAX - 20) + '\n…（已截断）';

async function post(payload) {
  const res = await fetch(URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(15000),
  });
  const t = await res.text();
  return { status: res.status, body: t };
}

const signed = signPayload();   // 未配 FEISHU_SECRET 时是 {}

let result;
try {
  // 飞书自定义机器人：{"msg_type":"text","content":{"text":"..."}, timestamp, sign}
  result = await post({ ...signed, msg_type: 'text', content: { text } });
  const okResp = /"(StatusCode|code)"\s*:\s*0/.test(result.body) || /"ok"/.test(result.body);
  if (!okResp) {
    // 企业微信是 {"msgtype":"text","text":{"content":"..."}} —— 退回通用格式再试一次
    const alt = await post({ msgtype: 'text', text: { content: text } });
    result = { status: alt.status, body: result.body + ' | alt: ' + alt.body };
  }
} catch (e) {
  console.error('[notify] 发送失败（不影响主流程）:', e.message);
  process.exit(0);   // 通知失败绝不能让主任务失败
}

const ok = /"(StatusCode|code)"\s*:\s*0|"ok"/.test(result.body);
console.log(`[notify] HTTP ${result.status}${SECRET ? ' (已签名)' : ''}  ${result.body.slice(0, 300)}`);
if (!ok) console.error('[notify] 机器人返回非成功码（不影响主流程）');
process.exit(0);   // 无论如何都不让通知影响主任务
