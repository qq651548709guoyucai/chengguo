// 影视（电影/电视剧/综艺/动漫）API 代理
// 数据源：苹果CMS VOD API（无尽资源主源 + 红牛资源备源）
// 版权提示：这些站聚合全网资源，版权状态不明，仅限个人/小范围自用。

// 内置内存缓存（与 server.mjs 的同款逻辑，避免跨模块耦合）
const memCache = new Map()
function cached(key, ttlMs, producer) {
  const hit = memCache.get(key)
  if (hit && Date.now() - hit.at < ttlMs) return Promise.resolve(hit.data)
  return Promise.resolve().then(producer).then((data) => {
    memCache.set(key, { at: Date.now(), data })
    return data
  })
}

const SOURCES = [
  { name: 'wj', base: 'https://api.wujinapi.com/api.php/provide/vod/at/json' },
  { name: 'hn', base: 'https://www.hongniuzy2.com/api.php/provide/vod/at/json' },
]

// 分类映射（统一成 App 端 5 个 tab）
// wj: 7喜剧片 11剧情片 13国产剧 15台湾剧 16美国剧 22韩国剧 23日本剧 24海外剧 25大陆综艺 26日韩综艺 27港台综艺 28欧美综艺 29国产动漫 30日韩动漫 37泰剧
// hn: 12国产剧 14日剧 15欧美剧 21伦理片 36中国动漫 42欧美综艺 ...
const CATEGORIES = [
  { key: 'movie',   label: '电影',     wj: '11', hn: '21' },
  { key: 'tv',      label: '电视剧',   wj: '13', hn: '12' },
  { key: 'variety', label: '综艺',     wj: '25', hn: '42' },
  { key: 'anime',   label: '动漫',     wj: '29', hn: '36' },
  // 短剧（竖屏爽剧，稳定源）：无尽 59=现代都市(1.2万+部)，红牛 44=现代都市(1.6万+部)。
  // 走苹果CMS 稳定源，不依赖红果逆向接口，彻底规避短剧播放反复失效。
  { key: 'short',   label: '短剧',     wj: '59', hn: '44' },
  { key: 'all',     label: '全部',     wj: '',   hn: '' },
]

async function fetchText(url) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 12000)
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: { 'User-Agent': 'Mozilla/5.0' } })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    return await r.text()
  } finally { clearTimeout(timer) }
}

async function fetchJSON(url) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 15000)
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: { 'User-Agent': 'Mozilla/5.0' } })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    return await r.json()
  } finally { clearTimeout(timer) }
}

// 把 master m3u8（含 EXT-X-STREAM-INF）展开成子 m3u8（纯 ts 分片）。
// 原因：资源站 master 的 BANDWIDTH 普遍严重虚标（如标 128 实际 1000k），
// iOS AVPlayer 的 ABR 会因此判断错乱导致黑屏；子 m3u8 是标准格式，兼容性最好。
// 展平结果做内存缓存，避免同一地址重复请求。
async function resolveM3U8(masterUrl) {
  if (!/^https?:\/\//i.test(masterUrl) || !/\.m3u8/i.test(masterUrl)) return masterUrl
  return cached(`m3u8flat:${masterUrl}`, 60 * 60 * 1000, async () => {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const text = await fetchText(masterUrl)
        if (!/#EXT-X-STREAM-INF/.test(text)) return masterUrl // 已是子 m3u8
        const lines = text.split(/\r?\n/)
        let bestUri = null, bestBandwidth = -1
        for (let i = 0; i < lines.length; i++) {
          if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
            const bm = lines[i].match(/BANDWIDTH=(\d+)/i)
            const bw = bm ? parseInt(bm[1], 10) : 0
            for (let j = i + 1; j < lines.length; j++) {
              const u = lines[j].trim()
              if (u && !u.startsWith('#')) {
                // 选带宽最高的一路（通常最清晰），统一绕开虚标带宽的 ABR 问题
                if (bw > bestBandwidth) { bestBandwidth = bw; bestUri = u }
                break
              }
            }
          }
        }
        if (bestUri) return new URL(bestUri, masterUrl).toString()
        return masterUrl
      } catch (e) { /* 重试 */ }
    }
    return masterUrl // 展平失败则回退原地址
  })
}

// 依次尝试各数据源，首个成功的返回
async function trySources(buildPath) {
  let lastErr
  for (const s of SOURCES) {
    try {
      const data = await fetchJSON(s.base + buildPath(s))
      if (data && data.code === 1) return { source: s.name, data }
      lastErr = new Error('源返回异常: ' + (data && data.msg))
    } catch (e) { lastErr = e }
  }
  throw lastErr || new Error('所有数据源不可用')
}

function normalizeItem(it, source) {
  return {
    id: String(it.vod_id),
    source,
    title: it.vod_name || '',
    cover: it.vod_pic || '',
    year: it.vod_year || '',
    area: it.vod_area || '',
    typeName: it.type_name || '',
    remarks: it.vod_remarks || '',       // 更新至X集 /  HD/完整版
    score: it.vod_douban_score || it.vod_score || '',
    actors: (it.vod_actor || '').slice(0, 80),
    director: it.vod_director || '',
  }
}

// 播放列表字符串解析： "第01集$url#第02集$url#..."
// 电影通常单集，标题可能是 "正片$url"
function parsePlayUrl(raw) {
  const out = []
  if (!raw) return out
  String(raw).split('#').forEach((seg, i) => {
    if (!seg) return
    const idx = seg.indexOf('$')
    let title, url
    if (idx >= 0) { title = seg.slice(0, idx); url = seg.slice(idx + 1) }
    else { title = `第${i + 1}集`; url = seg }
    if (url && /^https?:\/\//i.test(url)) out.push({ title, url, index: i })
  })
  return out
}

// 列表 / 搜索
export async function listVod(req, res) {
  const cat = (req.query.cat || 'all').toString()
  const pg = Math.max(1, parseInt(req.query.pg || '1', 10) || 1)
  const wd = (req.query.wd || '').toString().trim()
  const conf = CATEGORIES.find((c) => c.key === cat) || CATEGORIES[CATEGORIES.length - 1]
  const ck = `vod:${wd ? 's:' + wd : cat}:${pg}`

  const result = await cached(ck, 10 * 60 * 1000, async () => {
    const { source, data } = await trySources((s) => {
      let p = `?ac=${wd ? 'list' : 'list'}&pg=${pg}`
      if (wd) p += `&wd=${encodeURIComponent(wd)}`
      else {
        const tid = s.name === 'hn' ? conf.hn : conf.wj
        if (tid) p += `&t=${tid}`
      }
      return p
    })
    // 注意：资源站列表接口 ac=list 不返回 vod_pic（封面）等详情字段，
    // 需用详情接口 ac=detail&ids=... 批量补全，否则列表页封面全空。
    let detailMap = {}
    try {
      const ids = (data.list || []).map((it) => it.vod_id).filter(Boolean).slice(0, 60).join(',')
      if (ids) {
        const base = (SOURCES.find((s) => s.name === source) || SOURCES[0]).base
        const dd = await fetchJSON(`${base}?ac=detail&ids=${encodeURIComponent(ids)}`)
        if (dd && dd.code === 1 && Array.isArray(dd.list)) {
          for (const d of dd.list) detailMap[String(d.vod_id)] = d
        }
      }
    } catch (e) { /* 详情补全失败不影响列表主体 */ }

    const items = (data.list || []).map((it) => {
      const d = detailMap[String(it.vod_id)] || {}
      // 详情字段补全列表缺失项（vod_pic/vod_year/vod_area/vod_actor…）；
      // 列表已有字段（如 vod_remarks 更新集数）优先保留。
      return normalizeItem({ ...d, ...it, vod_pic: d.vod_pic || it.vod_pic || '' }, source)
    })
    return {
      items,
      page: parseInt(data.page || pg, 10),
      pagecount: parseInt(data.pagecount || 1, 10),
      total: parseInt(data.total || items.length, 10),
      source,
    }
  })
  res.json(result)
}

// 分类清单
export function vodCategories(req, res) {
  res.json({ categories: CATEGORIES.map(({ key, label }) => ({ key, label })) })
}

// 详情 + 播放列表
export async function detailVod(req, res) {
  const id = (req.query.id || '').toString().trim()
  const source = (req.query.source || '').toString().trim()
  if (!id) return res.status(400).json({ error: '缺少 id' })

  const ck = `vod:detail:${source}:${id}`
  const detail = await cached(ck, 30 * 60 * 1000, async () => {
    // 优先用指定源；失败则遍历其他源
    const order = source ? SOURCES.filter((s) => s.name === source).concat(SOURCES.filter((s) => s.name !== source)) : SOURCES
    let lastErr
    for (const s of order) {
      try {
        const data = await fetchJSON(`${s.base}?ac=detail&ids=${encodeURIComponent(id)}`)
        if (data && data.code === 1 && data.list && data.list.length) {
          const it = data.list[0]
          const playFrom = (it.vod_play_from || '').split('$$$')
          // 优先 m3u8 线路
          let lineIdx = playFrom.findIndex((f) => /m3u8/i.test(f))
          if (lineIdx < 0) lineIdx = 0
          const playUrls = (it.vod_play_url || '').split('$$$')
          const rawEpisodes = parsePlayUrl(playUrls[lineIdx] || playUrls[0])
          // 展平每集的 master m3u8 → 子 m3u8，规避 iOS 黑屏。
          // 分批并发（每批 5 个）避免瞬时打满资源站被限流；失败自动回退原地址。
          const episodes = [...rawEpisodes]
          for (let i = 0; i < episodes.length; i += 5) {
            const batch = episodes.slice(i, i + 5)
            const resolved = await Promise.all(batch.map((ep) => resolveM3U8(ep.url)))
            batch.forEach((ep, k) => { ep.url = resolved[k] })
          }
          return {
            ...normalizeItem(it, s.name),
            content: (it.vod_content || '').replace(/<[^>]+>/g, '').slice(0, 1200),
            playFrom: playFrom[lineIdx] || '',
            episodes,
          }
        }
        lastErr = new Error('详情为空')
      } catch (e) { lastErr = e }
    }
    throw lastErr || new Error('获取详情失败')
  })
  res.json(detail)
}
