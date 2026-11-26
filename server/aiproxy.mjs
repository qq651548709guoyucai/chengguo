// AI 中转代理：把 App 的 AI 请求转到上游，强制非流式，避免手机网络读 SSE 断流。
// 上游地址与 Key 走 .env（AI_UPSTREAM_BASE / AI_UPSTREAM_KEY），不下发到 App。
// 路由：
//   POST /api/ai/chat/completions  -> 上游 /v1/chat/completions
//   POST /api/ai/responses         -> 上游 /v1/responses
// 两者都强制非流式，拿到完整 JSON 再返回。

const UPSTREAM_BASE = (process.env.AI_UPSTREAM_BASE || 'https://tokenopen.dev').replace(/\/+$/, '')
const UPSTREAM_KEY = process.env.AI_UPSTREAM_KEY || ''

function cleanBody(body) {
  const b = { ...(body || {}) }
  // 强制非流式：chat completions 用 stream:false；responses 直接删掉 stream（默认非流）
  delete b.stream
  delete b.stream_options
  if (b.model === undefined || b.model === null || b.model === '') b.model = 'gpt-6.1-sol'
  return b
}

async function forward(pathname, req, res) {
  if (!UPSTREAM_KEY) {
    return res.status(500).json({ error: '服务端未配置 AI_UPSTREAM_KEY' })
  }
  const body = cleanBody(req.body)
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 120000)
  try {
    const r = await fetch(UPSTREAM_BASE + pathname, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + UPSTREAM_KEY,
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    })
    const text = await r.text()
    let out
    try { out = JSON.parse(text) } catch { out = { error: '上游返回非 JSON', raw: text.slice(0, 500) } }
    // 透传上游状态码；App 端能正常读错误文案
    res.status(r.status).json(out)
  } catch (e) {
    const msg = e && e.name === 'AbortError' ? '上游请求超时' : (e && e.message) || '未知错误'
    res.status(502).json({ error: '中转请求失败: ' + msg })
  } finally {
    clearTimeout(timer)
  }
}

export function aiChatCompletions(req, res) {
  return forward('/v1/chat/completions', req, res)
}

export function aiResponses(req, res) {
  return forward('/v1/responses', req, res)
}

// 供自检：返回配置状态（不暴露 Key 明文）
export function aiProxyStatus() {
  return {
    configured: !!UPSTREAM_KEY,
    upstream: UPSTREAM_BASE,
    keyTail: UPSTREAM_KEY ? UPSTREAM_KEY.slice(-6) : '',
  }
}
