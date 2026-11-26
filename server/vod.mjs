// 影视（电影/电视剧/综艺/动漫）API 代理
// 数据源：6 个苹果CMS VOD 资源站，App 端可切换线路；默认自动按可用性回退。
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

// 6 个苹果CMS资源站（2026-11-26 实测列表+详情+m3u8均可用）。
// types: name->id 映射，用于把 App 的"电影/电视剧"等 tab 翻译成该站的分类 ID。
const SOURCES = [
  { name: 'wj',  label: '无尽', base: 'https://api.wujinapi.com/api.php/provide/vod/at/json',
    types: { 剧情片:'11', 爱情片:'8', 犯罪片:'34', 国产剧:'13', 韩国剧:'22', 日本剧:'23', 美国剧:'16', 海外剧:'24',
             大陆综艺:'25', 日韩综艺:'26', 港台综艺:'27', 欧美综艺:'28', 国产动漫:'29', 日韩动漫:'30', 漫剧:'63' } },
  { name: 'hn',  label: '红牛', base: 'https://www.hongniuzy2.com/api.php/provide/vod/at/json',
    types: { 国产剧:'12', 港澳剧:'13', 韩剧:'18', 欧美剧:'15', 大陆综艺:'39', 中国动漫:'36', 日本动漫:'37', 欧美动漫:'38', 现代都市:'44' } },
  { name: 'bd',  label: '百度', base: 'https://api.apibdzy.com/api.php/provide/vod/at/json',
    types: { 大陆剧:'13', 欧美剧:'14', 韩剧:'15', 日剧:'16', 泰剧:'19', 大陆综艺:'25', 日韩综艺:'26', 港台综艺:'27', 欧美综艺:'28', 国产动漫:'29', 日韩动漫:'30' } },
  { name: 'gs',  label: '光速', base: 'https://api.guangsuapi.com/api.php/provide/vod/at/json',
    types: { 剧情片:'10', 动作片:'6', 恐怖片:'11', 战争片:'12', 大陆剧:'13', 欧美剧:'14', 港澳剧:'15', 韩剧:'16', 日剧:'21',
             大陆综艺:'37', 日韩综艺:'38', 中国动漫:'41', 日本动漫:'42', 欧美动漫:'43', 现代都市:'45' } },
  { name: 'jy',  label: '金鹰', base: 'https://jyzyapi.com/api.php/provide/vod/at/json',
    types: { 剧情片:'14', 动作片:'9', 恐怖片:'13', 战争片:'15', 内地剧:'20', 香港剧:'4', 欧美剧:'3', 韩剧:'5', 日剧:'6',
             大陆综艺:'36', 日韩综艺:'37', 中国动漫:'24', 日本动漫:'25', 欧美动漫:'26', 现代都市:'41' } },
  { name: 'js',  label: '极速', base: 'https://jszyapi.com/api.php/provide/vod/at/json',
    types: { 剧情片:'14', 伦理片:'8', 内地剧:'20', 欧美剧:'3', 韩剧:'5', 日剧:'6', 大陆综艺:'30', 日韩综艺:'31', 港台综艺:'32', 中国动漫:'24', 现代都市:'46', AI漫剧:'54' } },
]

// App 端 6 个 tab。每个分类给一组候选类型名，按优先级在各源里找匹配（找不到就整站 list=全部）。
const CATEGORIES = [
  { key: 'movie',   label: '电影',   names: ['剧情片','动作片','爱情片','犯罪片','恐怖片','战争片','动漫电影'] },
  { key: 'tv',      label: '电视剧', names: ['国产剧','大陆剧','内地剧','港澳剧','香港剧','韩剧','日剧','欧美剧','美国剧','海外剧'] },
  { key: 'variety', label: '综艺',   names: ['大陆综艺','日韩综艺','港台综艺','欧美综艺'] },
  { key: 'anime',   label: '动漫',   names: ['国产动漫','中国动漫','日韩动漫','日本动漫','欧美动漫'] },
  { key: 'short',   label: '短剧',   names: ['现代都市','漫剧','AI漫剧'] },
  { key: 'all',     label: '全部',   names: [] },
]

// 给定源+分类，算出该站的类型 ID（第一个匹配到的候选名）
function typeIdFor(source, conf) {
  for (const n of conf.names) if (source.types[n]) return source.types[n]
  return ''   // 无匹配 → 该站全部
}

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

// 依次尝试数据源，首个成功的返回。prefer=指定源优先（失败仍回退其他源）。
async function trySources(buildPath, prefer) {
  const order = prefer
    ? SOURCES.filter((s) => s.name === prefer).concat(SOURCES.filter((s) => s.name !== prefer))
    : SOURCES
  let lastErr
  for (const s of order) {
    try {
      const data = await fetchJSON(s.base + buildPath(s))
      if (data && data.code === 1 && Array.isArray(data.list)) return { source: s.name, data }
      lastErr = new Error('源返回异常: ' + (data && data.msg))
    } catch (e) { lastErr = e }
  }
  throw lastErr || new Error('所有数据源不可用')
}

// 供 App 展示可选线路
export function vodSources(req, res) {
  res.json({ sources: SOURCES.map(({ name, label }) => ({ name, label })) })
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
  // 指定线路；为空=自动（按 SOURCES 顺序挑第一个可用）
  const prefer = (req.query.source || '').toString().trim()
  const conf = CATEGORIES.find((c) => c.key === cat) || CATEGORIES[CATEGORIES.length - 1]
  const ck = `vod:${prefer || 'auto'}:${wd ? 's:' + wd : cat}:${pg}`

  const result = await cached(ck, 10 * 60 * 1000, async () => {
    const { source, data } = await trySources((s) => {
      let p = `?ac=list&pg=${pg}`
      if (wd) p += `&wd=${encodeURIComponent(wd)}`
      else {
        const tid = typeIdFor(s, conf)
        if (tid) p += `&t=${tid}`
      }
      return p
    }, prefer)
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
