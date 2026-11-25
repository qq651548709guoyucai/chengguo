// 首页短剧「稳定源」：把苹果CMS短剧翻译成 App 现有的红果数据格式，
// 并提供 HLS 反向代理（m3u8 改写 + 分片透传），让 iOS 只连本机服务器，
// 彻底绕开红果逆向接口失效 + 手机直连第三方 CDN 被拦的黑屏问题。
// 仅限个人/小范围自用。
const WJ = 'https://api.wujinapi.com/api.php/provide/vod/at/json'
const BASE = 'http://47.100.207.19' // App 的 Api.base
const EP_PREFIX = 'vod_'
const VOD_TYPES = [
  { type: 'real',  wj: '59' }, // 现代都市（竖屏爽剧主力）
  { type: 'comic', wj: '58' }, // 古装仙侠
  { type: 'ai',    wj: '56' }, // 脑洞悬疑
]

async function fetchJSON(url, timeout = 15000) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeout)
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: { 'User-Agent': 'Mozilla/5.0' } })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    return await r.json()
  } finally { clearTimeout(timer) }
}
async function fetchText(url, timeout = 15000) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeout)
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: { 'User-Agent': 'Mozilla/5.0' } })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    return await r.text()
  } finally { clearTimeout(timer) }
}

function parseEpCount(remarks) {
  const m = String(remarks || '').match(/(\d+)\s*集/)
  return m ? parseInt(m[1], 10) : 0
}
function toSeries(it) {
  return {
    id: EP_PREFIX + it.vod_id,
    title: it.vod_name || '',
    coverUrl: it.vod_pic || '',
    description: (it.vod_content || '').replace(/<[^>]+>/g, '').slice(0, 120) || (it.vod_remarks || ''),
    episodeCount: parseEpCount(it.vod_remarks) || 1,
  }
}

// 列表接口 ac=list 不返回 vod_pic，需用详情接口 ac=detail&ids=... 批量补全封面
async function withCovers(items) {
  try {
    const ids = items.map((it) => String(it.id).replace(EP_PREFIX, '')).filter((x) => /^\d+$/.test(x)).slice(0, 60).join(',')
    if (!ids) return items
    const d = await fetchJSON(`${WJ}?ac=detail&ids=${encodeURIComponent(ids)}`)
    const map = new Map()
    for (const x of (d.list || [])) map.set(String(x.vod_id), x.vod_pic || '')
    return items.map((it) => {
      const pic = map.get(String(it.id).replace(EP_PREFIX, ''))
      return pic ? { ...it, coverUrl: pic } : it
    })
  } catch { return items }
}

// master m3u8 → 子 m3u8（带宽虚标会导致 iOS 黑屏，展平到最高清子流）
async function resolveM3U8(masterUrl) {
  try {
    const text = await fetchText(masterUrl)
    if (!/#EXT-X-STREAM-INF/.test(text)) return masterUrl
    const lines = text.split(/\r?\n/)
    let best = null, bestBw = -1
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        const bm = lines[i].match(/BANDWIDTH=(\d+)/i)
        const bw = bm ? parseInt(bm[1], 10) : 0
        for (let j = i + 1; j < lines.length; j++) {
          const u = lines[j].trim()
          if (u && !u.startsWith('#')) {
            if (bw > bestBw) { bestBw = bw; best = u }
            break
          }
        }
      }
    }
    return best ? new URL(best, masterUrl).toString() : masterUrl
  } catch { return masterUrl }
}

function proxied(url) {
  return `${BASE}/api/vodseg?u=${encodeURIComponent(url)}`
}

// ---------- 对外接口（红果格式） ----------

export async function stableFeed(type = 'real') {
  const conf = VOD_TYPES.find((t) => t.type === type) || VOD_TYPES[0]
  const data = await fetchJSON(`${WJ}?ac=list&t=${conf.wj}&pg=1`)
  const items = (data.list || []).slice(0, 60).map(toSeries)
  return { items: await withCovers(items), cursor: '', hasMore: false }
}

export async function stableSearch(q) {
  const data = await fetchJSON(`${WJ}?ac=list&wd=${encodeURIComponent(q)}&pg=1`)
  const items = (data.list || []).slice(0, 60).map(toSeries)
  return { items: await withCovers(items), cursor: '', hasMore: false }
}

export async function stableHot() {
  const data = await fetchJSON(`${WJ}?ac=list&t=${VOD_TYPES[0].wj}&pg=1`)
  let items = (data.list || []).slice(0, 20).map((it, i) => ({
    ...toSeries(it), rank: i + 1, tag: it.vod_remarks || '全集', board: '稳定热播',
  }))
  items = await withCovers(items)
  return { items }
}

// 苹果CMS短剧整部单集，返回 1 集
export async function stableEpisodes(seriesId) {
  const id = String(seriesId || '').replace(EP_PREFIX, '')
  if (!/^\d+$/.test(id)) return { items: [], cursor: '', hasMore: false }
  return { items: [{ id: EP_PREFIX + id, title: '全集' }], cursor: '', hasMore: false }
}

// 取某集展平后的源 m3u8
export async function stableM3U8Url(episodeId) {
  const id = String(episodeId || '').replace(EP_PREFIX, '')
  if (!/^\d+$/.test(id)) throw new Error('invalid vod id')
  const data = await fetchJSON(`${WJ}?ac=detail&ids=${id}`)
  const it = data.list && data.list[0]
  if (!it) throw new Error('vod not found')
  const playFrom = (it.vod_play_from || '').split('$$$')
  const playUrls = (it.vod_play_url || '').split('$$$')
  const lineIdx = playFrom.findIndex((f) => /m3u8/i.test(f))
  const raw = (playUrls[lineIdx < 0 ? 0 : lineIdx] || '').split('#')[0]
  const url = raw.indexOf('$') >= 0 ? raw.slice(raw.indexOf('$') + 1) : raw
  if (!/^https?:\/\//i.test(url)) throw new Error('no m3u8 url')
  return resolveM3U8(url)
}

// HLS 反向代理：m3u8 内所有 URI 改写成本机代理
export async function serveHLS(req, res, rawUrl) {
  let url
  try { url = decodeURIComponent(rawUrl) } catch { url = rawUrl }
  if (!/^https?:\/\//i.test(url)) return res.status(400).end('bad url')
  const text = await fetchText(url)
  const out = rewriteM3U8(text, url)
  res.setHeader('Content-Type', 'application/vnd.apple.mpegurl')
  res.setHeader('Cache-Control', 'no-cache')
  res.send(out)
  // 后台预取前 12 片：第三方 CDN 下载慢(2~25秒/片)，提前转码存缓存，
  // 让 App 顺序播放时直接命中缓存，避免缓冲跟不上导致卡死。（不阻塞本次响应）
  if ((process.env.CLEAN_AD ?? '1') !== '0') {
    fetch('http://172.17.0.1:8899/prefetch?m3u8=' + encodeURIComponent(url),
      { signal: AbortSignal.timeout(8000) }).catch(() => {})
  }
}

// 把一个 m3u8 文本里的所有 URI 改写成本机代理地址
function rewriteM3U8(text, baseUrl) {
  const base = new URL(baseUrl)
  return text.split(/\r?\n/).map((line) => {
    const t = line.trim()
    if (!t) return line
    if (t.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_m, uri) => {
        try { return `URI="${proxied(new URL(uri, base).toString())}"` } catch { return `URI="${uri}"` }
      })
    }
    try { return proxied(new URL(t, base).toString()) } catch { return line }
  }).join('\n')
}

// 分片透传，支持 Range；若目标其实是 m3u8（master 的第二层），同样改写
export async function serveSegment(req, res, rawUrl) {
  let url
  try { url = decodeURIComponent(rawUrl) } catch { url = rawUrl }
  if (!/^https?:\/\//i.test(url)) return res.status(400).end('bad url')
  const headers = { 'User-Agent': 'Mozilla/5.0' }
  if (req.headers.range) headers.Range = req.headers.range

  // 去广告：TS 分片转发到宿主机转码服务（高斯模糊烧录的博彩横幅）。
  // 仅在开启 CLEAN_AD 且是 .ts 分片时启用；失败自动回退原链路，不中断播放。
  const CLEAN_AD = (process.env.CLEAN_AD ?? '1') !== '0'
  if (CLEAN_AD && /\.ts(?:\?|$)/i.test(url)) {
    try {
      const enc = encodeURIComponent(url)
      // 先探测缓存：命中直接取(秒回)；未命中才等待转码，且最多等 12 秒，超时回退原始分片，
      // 避免播放器长时间干等导致卡死（第三方 CDN 下载有时高达 25 秒）。
      let cached = false
      try {
        const probe = await fetch('http://172.17.0.1:8899/cached?u=' + enc,
          { signal: AbortSignal.timeout(2000) })
        cached = probe.ok
      } catch (e) { /* 探测失败当作未命中 */ }
      const timeout = cached ? 8000 : 20000
      const cleaner = 'http://172.17.0.1:8899/?u=' + enc
      const cr = await fetch(cleaner, { signal: AbortSignal.timeout(timeout) })
      if (cr.ok) {
        const buf = Buffer.from(await cr.arrayBuffer())
        res.status(200)
        res.setHeader('Content-Type', 'video/mp2t')
        res.setHeader('Content-Length', String(buf.length))
        res.setHeader('Accept-Ranges', 'bytes')
        res.setHeader('X-Ad-Cleaned', cr.headers.get('x-clean-cache') || 'yes')
        res.send(buf)
        return
      }
    } catch (e) { /* 转码超时/不可用 → 回退原链路，保证播放不中断 */ }
  }

  const r = await fetch(url, { headers, redirect: 'follow' })
  const ct = r.headers.get('content-type') || ''
  // m3u8：改写内部 URI（含 master→子列表的第二层）
  if (/\.m3u8/i.test(url) || /mpegurl/i.test(ct)) {
    const text = await r.text()
    res.setHeader('Content-Type', 'application/vnd.apple.mpegurl')
    res.setHeader('Cache-Control', 'no-cache')
    res.send(rewriteM3U8(text, r.url || url))
    return
  }
  res.status(r.status)
  res.setHeader('Content-Type', ct || 'video/mp2t')
  res.setHeader('Accept-Ranges', 'bytes')
  const cr = r.headers.get('content-range'); if (cr) res.setHeader('Content-Range', cr)
  const cl = r.headers.get('content-length'); if (cl) res.setHeader('Content-Length', cl)
  // 流式透传：边下边发给 App，AVPlayer 可边下边播，避免慢 CDN 导致缓冲卡死
  if (r.body) {
    const { Readable } = await import('stream')
    Readable.fromWeb(r.body).pipe(res)
  } else {
    res.send(Buffer.from(await r.arrayBuffer()))
  }
}
