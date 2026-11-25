// 自建红果 REST 代理（worker 隔离版）
// 每个 SDK 调用在独立子进程执行：卡死请求被超时强杀重试，主进程永远响应。
// 端点：
//   GET /api/feed                      推荐流
//   GET /api/search?q=                 搜索
//   GET /api/hot                       热搜词
//   GET /api/episodes/:seriesId        分集列表（?cursor= 翻页）
//   GET /api/play/:episodeId           播放信息（含加密流的 key）
//   GET /api/stream/:episodeId         解密后的 mp4 流（支持 Range，可 ?q=540p）
// 读取同目录 .env 配置文件（Node 原生，无需 dotenv）：KEY=VALUE 每行一项，# 开头为注释。
// 已有环境变量优先于 .env，方便命令行临时覆盖。
import fs0 from 'node:fs'
try {
  const envPath = new URL('./.env', import.meta.url)
  if (fs0.existsSync(envPath)) {
    for (const line of fs0.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
      const s = line.trim()
      if (!s || s.startsWith('#')) continue
      const i = s.indexOf('=')
      if (i < 0) continue
      const k = s.slice(0, i).trim()
      const v = s.slice(i + 1).trim()
      if (k && process.env[k] === undefined) process.env[k] = v
    }
    console.log('[config] 已加载 .env')
  }
} catch (e) { console.error('[config] 读取 .env 失败:', e.message) }
import express from 'express'
import {
  authMiddleware, adminMiddleware, superAdminMiddleware, register, login, me, changePassword,
  syncData, getData, adminListUsers, adminStats, adminToggleUser, adminDeleteUser,
  adminListAdmins, adminCreateAdmin, adminPromoteUser, adminDemoteAdmin, isValidToken,
} from './auth.mjs'
import { postComment, listComments, deleteComment, adminListComments, adminDeleteComment } from './comments.mjs'
import {
  listAnnouncements, adminListAnnouncements, addAnnouncement,
  updateAnnouncement, deleteAnnouncement,
} from './announcements.mjs'
import { listVod, vodCategories, detailVod } from './vod.mjs'
import { getWatermark, updateWatermark } from './watermark.mjs'
import {
  stableFeed, stableSearch, stableHot, stableEpisodes,
  stableM3U8Url, serveHLS, serveSegment,
} from './stablefeed.mjs'
import { spawn } from 'child_process'
import { decryptFile } from './mp4decrypt.mjs'
import fs from 'fs'
import https from 'https'
import path from 'path'
import { fileURLToPath } from 'url'

// 用 Node 原生 https 流式下载（undici fetch 对该 CDN 响应会报 size out of range）
function downloadTo(url, dest, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error('too many redirects'))
    const req = https.get(url, { headers: { 'User-Agent': 'okhttp/4.9.3', 'Accept-Encoding': 'identity' }, timeout: 180_000 }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        res.resume()
        const next = new URL(res.headers.location, url).toString()
        return resolve(downloadTo(next, dest, redirects + 1))
      }
      if (res.statusCode !== 200) {
        res.resume()
        return reject(new Error(`download HTTP ${res.statusCode}`))
      }
      const out = fs.createWriteStream(dest)
      res.pipe(out)
      out.on('finish', () => out.close(() => resolve()))
      out.on('error', reject)
    })
    req.on('timeout', () => req.destroy(new Error('download timeout')))
    req.on('error', reject)
  })
}

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const CACHE_DIR = path.join(__dirname, 'cache')
const CACHE_MAX_BYTES = 3 * 1024 * 1024 * 1024
fs.mkdirSync(CACHE_DIR, { recursive: true })

// ---------- worker 调度 ----------
const WORKER_TIMEOUT = 40_000
const MAX_CONCURRENT = 6
let running = 0
const queue = []

// 设备档案被风控时删除，下次自动注册新设备
function rotateDevice() {
  try {
    fs.rmSync(path.join(__dirname, '.config/openhongguo/anonymous.json'), { force: true })
    console.error('[rotate] 设备档案已重置')
  } catch {}
}

// 自我限流：两次 SDK 调用间隔，避免触发红果风控（内存缓存已承担重复请求，这里可放宽）
let lastCall = 0
const MIN_INTERVAL = 1200
function rateGate() {
  return new Promise((resolve) => {
    const wait = Math.max(0, lastCall + MIN_INTERVAL - Date.now())
    lastCall = Math.max(lastCall + MIN_INTERVAL, Date.now())
    setTimeout(resolve, wait)
  })
}

function pump() {
  while (running < MAX_CONCURRENT && queue.length) {
    const job = queue.shift()
    running++
    job.start().finally(() => { running--; pump() })
  }
}

function runWorker(task) {
  return new Promise((resolve, reject) => {
    queue.push({
      start: () => new Promise((done) => {
        let attempt = 0
        const tryOnce = async () => {
          attempt++
          await rateGate()
          console.log(`[worker] spawn ${task.op} attempt=${attempt}`)
          const child = spawn(process.execPath, [path.join(__dirname, 'worker.mjs')], {
            cwd: __dirname, env: { ...process.env, HOME: __dirname },
          })
          child.on('error', (e) => fail(`spawn: ${e.message}`))
          let out = ''
          let errOut = ''
          const timer = setTimeout(() => {
            child.kill('SIGKILL')
            errOut += ' worker-timeout'
          }, WORKER_TIMEOUT)
          child.stdout.on('data', (d) => { out += d })
          child.stderr.on('data', (d) => { errOut += d })
          child.stdin.write(JSON.stringify(task))
          child.stdin.end()
          child.on('close', (code) => {
            clearTimeout(timer)
            console.log(`[worker] close ${task.op} attempt=${attempt} code=${code} outLen=${out.length}`)
            if (code === 0 && out.trim().startsWith('{')) {
              try { resolve(JSON.parse(out)); done() } catch (e) { fail(String(e)) }
            } else {
              fail(errOut.slice(-200) || `exit ${code}`)
            }
          })
          const fail = (msg) => {
            // 设备被明确拒绝/卡死才换档案；ANONYMOUS_LIMITED 是服务端限流，
            // 换设备只会拿到信誉更低的新设备、陷入死循环——只做延迟重试
            const deviceRejected = /timeout|超时|device rejected|APP_REJECT|signer refused/i.test(msg)
            const throttled = /ANONYMOUS_LIMITED|CONTENT_UNAVAILABLE|RATE_LIMITED|empty|空/i.test(msg)
            // 匿名设备"每台只给一次播放"，play 一旦失败就换档案，否则拿废设备重试必失败
            if (task.op === 'play' || deviceRejected) rotateDevice()
            const delay = throttled ? 4000 : (deviceRejected ? 2500 : 1500)
            if (attempt < 3) { setTimeout(tryOnce, delay) }
            else { reject(new Error(`worker 失败: ${msg.slice(0, 200)}`)); done() }
          }
        }
        tryOnce()
      }),
    })
    pump()
  })
}

// ---------- 缓存清理 ----------
function sweepCache() {
  try {
    const files = fs.readdirSync(CACHE_DIR).map((f) => {
      const st = fs.statSync(path.join(CACHE_DIR, f))
      return { f, size: st.size, mtime: st.mtimeMs }
    })
    let total = files.reduce((a, b) => a + b.size, 0)
    if (total <= CACHE_MAX_BYTES) return
    files.sort((a, b) => a.mtime - b.mtime)
    for (const file of files) {
      if (total <= CACHE_MAX_BYTES) break
      fs.rmSync(path.join(CACHE_DIR, file.f), { force: true })
      total -= file.size
    }
  } catch (e) { console.error('sweepCache:', e.message) }
}

// ---------- 内存缓存：episodes/hot 冷启动慢，缓存后秒回 ----------
const memCache = new Map()
function cached(key, ttlMs, producer) {
  const hit = memCache.get(key)
  if (hit && Date.now() - hit.at < ttlMs) return Promise.resolve(hit.data)
  return Promise.resolve().then(producer).then((data) => {
    memCache.set(key, { at: Date.now(), data })
    return data
  })
}

// ---------- feed 分类累积池 ----------
// 每个类型(real/comic/ai)独立池子：预约拉取多页去重累积，返回时打乱。
// 冷启动后缓存命中秒回；池子不足时后台静默续拉下一页。
const FEED_TYPES = ['real', 'comic', 'ai']
const feedPools = {}   // type -> { items:[], seen:Set, cursor:'', hasMore, fetchedAt, inflight }
for (const t of FEED_TYPES) feedPools[t] = { items: [], seen: new Set(), cursor: '', hasMore: true, fetchedAt: 0, inflight: null }

async function fetchFeedPage(type) {
  const pool = feedPools[type]
  if (pool.inflight) return pool.inflight
  pool.inflight = (async () => {
    const page = await runWorker({ op: 'feedByType', type, cursor: pool.cursor })
    let added = 0
    for (const it of (page.items || [])) {
      if (it && it.id && !pool.seen.has(it.id)) {
        pool.seen.add(it.id)
        pool.items.push(it)
        added++
      }
    }
    pool.cursor = page.cursor || ''
    pool.hasMore = page.hasMore ?? false
    pool.fetchedAt = Date.now()
    console.log(`[feed:${type}] +${added} 池子现有${pool.items.length}部 hasMore=${pool.hasMore}`)
    return page
  })().finally(() => { pool.inflight = null })
  return pool.inflight
}

function shuffled(a) {
  const r = a.slice()
  for (let i = r.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    const t = r[i]; r[i] = r[j]; r[j] = t
  }
  return r
}

const FEED_TARGET = 100   // 每类池子目标部数（冷启动尽快攒够，打开就是一大批）

async function getFeed(type = 'real') {
  const pool = feedPools[type] || feedPools.real
  // 池子不足目标且有下一页：连续多拉几页尽快攒够
  let guard = 0
  while (pool.items.length < FEED_TARGET && pool.hasMore && guard++ < 8) {
    await fetchFeedPage(type)
  }
  // 后台静默续拉，让池子持续变大（间隔缩短到 15 秒）
  if (pool.hasMore && Date.now() - pool.fetchedAt > 15 * 1000) fetchFeedPage(type).catch(() => {})
  return { items: shuffled(pool.items), cursor: '', hasMore: true }
}

// 服务启动后后台预热三类池子，避免冷启动首页只有 24 部
async function warmupPools() {
  console.log('[warmup] 开始预热三类池子...')
  for (const t of FEED_TYPES) {
    try {
      let g = 0
      while (feedPools[t].items.length < FEED_TARGET && feedPools[t].hasMore && g++ < 8) {
        await fetchFeedPage(t)
      }
      console.log(`[warmup] ${t} 预热完成 ${feedPools[t].items.length}部`)
    } catch (e) {
      console.log(`[warmup] ${t} 失败: ${String(e && e.message || e).slice(0, 120)}`)
    }
  }
  console.log('[warmup] 全部完成')
}

// ---------- 游客试看限制：未登录只能看前2集 ----------
// episodes 返回时按列表顺序记录每个 epId 的集数序号（0 基）。
// 红果的 index 字段常为 null，所以用返回顺序即集数。
const epOrder = new Map()   // episodeId -> 集数序号(0基)
function noteEpisodeOrder(items) {
  if (!Array.isArray(items)) return
  items.forEach((it, i) => {
    if (it && it.id != null) {
      const epId = String(it.id)
      if (!epOrder.has(epId)) epOrder.set(epId, i)
    }
  })
}
// 判断是否为「未登录且想看第3集及以后」。
// 修复 H2：必须校验 token 真实有效才放行；失效/伪造 token 一律按游客处理。
// App 端已有自动重登，token 失效时客户端会静默换 token 后重试，不会被误伤。
function isGuestLocked(req, epId) {
  const token = (req.headers['x-token'] || req.query.token || '').toString().trim()
  if (token && isValidToken(token)) return false   // 仅有效且未禁用的用户放行
  if (epOrder.size === 0) return false             // 映射还没建立：放行，避免误伤前2集播放
  const order = epOrder.get(String(epId))
  return order != null && order >= 2               // 第3集及以后且无有效 token：拦截
}

// 修复 H1：画质白名单 + epId 清洗，杜绝 path.join 路径遍历
const QUALITY_WHITELIST = new Set(['360p', '480p', '540p', '720p', '1080p'])
function safeQuality(q) {
  const s = (q || '1080p').toString()
  return QUALITY_WHITELIST.has(s) ? s : '1080p'
}
function safeEpId(raw) {
  return String(raw ?? '').replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 128)
}

// ---------- play 取址结果持久化缓存 ----------
// 红果匿名播放接口会周期性风控限流。成功取址一次就落盘，
// 命中缓存直接返回，不再求红果；已解密的视频流本身也有独立缓存。
const PLAY_CACHE_DIR = path.join(__dirname, 'playcache')
fs.mkdirSync(PLAY_CACHE_DIR, { recursive: true })
const playCachePath = (epId) => {
  const safe = safeEpId(epId)
  if (!safe) throw new Error('invalid episodeId')
  const p = path.join(PLAY_CACHE_DIR, `p_${safe}.json`)
  if (!path.resolve(p).startsWith(path.resolve(PLAY_CACHE_DIR) + path.sep)) {
    throw new Error('invalid play cache path')
  }
  return p
}

async function runPlayCached(epId) {
  const cf = playCachePath(epId)
  if (fs.existsSync(cf)) {
    try { return JSON.parse(fs.readFileSync(cf, 'utf8')) } catch {}
  }
  const info = await runWorker({ op: 'play', episodeId: epId })
  // 只有拿到真实流地址才缓存，避免把失败/空结果写进去
  if (info && Array.isArray(info.streams) && info.streams.some((s) => s && s.url)) {
    fs.writeFileSync(cf, JSON.stringify(info))
  }
  return info
}

// ---------- 流下载去重 ----------
const streamJobs = new Map()

// ---------- 服务 ----------
const app = express()
app.use(express.json({ limit: '2mb' }))

const wrap = (fn) => async (req, res) => {
  try {
    const out = await fn(req, res)
    if (out !== undefined && !res.headersSent) res.json(out)
  }
  catch (e) { res.status(502).json({ error: String(e && e.message || e).slice(0, 300) }) }
}

// ---------- 账号系统路由 ----------
app.post('/api/auth/register', wrap(register))
app.post('/api/auth/login', wrap(login))
app.get('/api/auth/me', authMiddleware, wrap(me))
app.post('/api/auth/change-password', authMiddleware, wrap(changePassword))
app.get('/api/data', authMiddleware, wrap(getData))
app.post('/api/data', authMiddleware, wrap(syncData))
// 管理后台
app.get('/api/admin/users', adminMiddleware, wrap(adminListUsers))
app.get('/api/admin/stats', adminMiddleware, wrap(adminStats))
app.post('/api/admin/toggle', adminMiddleware, wrap(adminToggleUser))
app.post('/api/admin/delete', adminMiddleware, wrap(adminDeleteUser))
// 管理员管理（仅超级管理员）
app.get('/api/admin/admins', adminMiddleware, wrap(adminListAdmins))
app.post('/api/admin/admins/create', superAdminMiddleware, wrap(adminCreateAdmin))
app.post('/api/admin/admins/promote', superAdminMiddleware, wrap(adminPromoteUser))
app.post('/api/admin/admins/demote', superAdminMiddleware, wrap(adminDemoteAdmin))
// 评论系统
app.post('/api/comments', authMiddleware, wrap(postComment))
app.get('/api/comments', authMiddleware, wrap(listComments))
app.post('/api/comments/delete', authMiddleware, wrap(deleteComment))
app.get('/api/admin/comments', adminMiddleware, wrap(adminListComments))
app.post('/api/admin/comments/delete', adminMiddleware, wrap(adminDeleteComment))
// 公告系统（公开拉取；增删改仅超级管理员）
app.get('/api/announcements', wrap(listAnnouncements))
app.get('/api/admin/announcements', adminMiddleware, wrap(adminListAnnouncements))
app.post('/api/admin/announcements/add', superAdminMiddleware, wrap(addAnnouncement))
app.post('/api/admin/announcements/update', superAdminMiddleware, wrap(updateAnnouncement))
app.post('/api/admin/announcements/delete', superAdminMiddleware, wrap(deleteAnnouncement))
// 去广告水印设置（公开拉取；修改仅超级管理员，改后清转码缓存）
app.get('/api/watermark', wrap(getWatermark))
app.post('/api/admin/watermark/update', superAdminMiddleware, wrap(async (req, res) => {
  const result = await updateWatermark(req, res)
  // 通知宿主机转码服务清空缓存，让新文字立即生效
  try {
    await fetch('http://172.17.0.1:8899/purge', { signal: AbortSignal.timeout(10000) })
  } catch (e) { /* 清缓存失败不影响配置已保存 */ }
  return result
}))

// ---------- 数据源设置（管理后台热切换，无需重启）----------
app.get('/api/admin/feed-mode', superAdminMiddleware, wrap(() => ({
  mode: feedState.mode,
  modes: [
    { key: 'stable', label: '苹果CMS稳定源', desc: '整部剧合成1个视频，稳定能播（推荐）' },
    { key: 'hg', label: '红果官方API', desc: '榜单发现 + 真实分集，出口IP被风控时会黑屏' },
    { key: 'legacy', label: '旧版 worker', desc: '早期红果 worker 逻辑' },
  ],
})))
app.post('/api/admin/feed-mode', superAdminMiddleware, wrap(async (req, res) => {
  const mode = (req.body?.mode || '').toString()
  if (!['stable', 'hg', 'legacy'].includes(mode)) {
    return res.status(400).json({ error: '无效的数据源模式' })
  }
  feedState.mode = mode
  process.env.HG_FEED = mode === 'hg' ? '1' : '0'
  process.env.STABLE_FEED = mode === 'legacy' ? '0' : '1'
  persistFeedMode(mode)
  // 清掉旧数据源的缓存，让切换立即生效
  for (const k of [...memCache.keys()]) {
    if (k.startsWith('sf:') || k.startsWith('hg:') || k.startsWith('feed:')
        || k.startsWith('search:') || k.startsWith('hot:') || k.startsWith('ep:') || k.startsWith('series:')) {
      memCache.delete(k)
    }
  }
  console.log(`[admin] 数据源切换为 ${mode}`)
  return { ok: true, mode }
}))

// 影视系统（电影/电视剧/综艺/动漫，公开拉取）
app.get('/api/vod/categories', wrap(vodCategories))
app.get('/api/vod/list', wrap(listVod))
app.get('/api/vod/detail', wrap(detailVod))
// HLS 分片反向代理（供稳定源 m3u8 内的分片/密钥使用）
app.get('/api/vodseg', wrap(async (req, res) => {
  await serveSegment(req, res, (req.query.u || '').toString())
}))

// 管理后台页面 + 静态资源
app.get('/admin', (req, res) => res.sendFile(path.join(__dirname, 'admin.html')))
app.use('/static', express.static(path.join(__dirname, 'static')))

// 首页短剧数据源开关（运行时可改，管理后台可调）：
//   hg      → 红果官方 API（榜单发现 + 真实分集 + 红果取址），真·一集一集
//   stable  → 苹果CMS稳定源（整部合成1个视频，绕开红果风控）【默认】
//   legacy  → 老 worker 逻辑
// 注意：红果取址（resolvePlayback）在部分出口 IP 会被 ANONYMOUS_LIMITED 风控，
// 若切到 hg 后出现黑屏/取址失败，请在管理后台切回 stable。
const ENV_PATH = new URL('./.env', import.meta.url)
const feedState = {
  mode: (process.env.HG_FEED ?? '0') === '1' ? 'hg'
    : ((process.env.STABLE_FEED ?? '1') !== '0' ? 'stable' : 'legacy'),
}
// 把当前模式持久化回 .env，重启后保持
function persistFeedMode(mode) {
  try {
    let text = fs0.existsSync(ENV_PATH) ? fs0.readFileSync(ENV_PATH, 'utf8') : ''
    const setKey = (key, val) => {
      const re = new RegExp(`^${key}=.*$`, 'm')
      if (re.test(text)) text = text.replace(re, `${key}=${val}`)
      else text = `${key}=${val}\n${text}`
    }
    setKey('HG_FEED', mode === 'hg' ? '1' : '0')
    setKey('STABLE_FEED', mode === 'legacy' ? '0' : '1')
    fs0.writeFileSync(ENV_PATH, text)
  } catch (e) { console.error('[config] 持久化 .env 失败:', e.message) }
}
const getHG = () => feedState.mode === 'hg'
const getStable = () => feedState.mode === 'stable'

app.get('/api/feed', wrap(async (req) => {
  const t = (req.query.type || 'real').toString()
  if (getHG()) return cached(`hg:feed:${t}`, 30 * 60 * 1000, () => runWorker({ op: 'hgFeed' }))
  if (getStable()) return cached(`sf:feed:${t}`, 30 * 60 * 1000, () => stableFeed(FEED_TYPES.includes(t) ? t : 'real'))
  return getFeed(FEED_TYPES.includes(t) ? t : 'real')
}))
app.get('/api/search', wrap(async (req) => {
  const q = (req.query.q || '').toString().trim()
  if (!q) return { items: [], cursor: '', hasMore: false }
  if (getStable()) return cached(`sf:search:${q}`, 30 * 60 * 1000, () => stableSearch(q))
  return cached(`search:${q}`, 30 * 60 * 1000, () => runWorker({ op: 'search', q }))
}))
app.get('/api/hot', wrap(() => {
  if (getStable()) return cached('sf:hot', 30 * 60 * 1000, () => stableHot())
  return cached('hot', 30 * 60 * 1000, () => runWorker({ op: 'hot' }))
}))

// ===== 红果官方 API 扩展（SDK 已封装的能力，直连红果 fqnovel.com）=====
// 搜索联想词
app.get('/api/suggest', wrap((req) => {
  const prefix = (req.query.prefix || req.query.q || '').toString().trim()
  if (!prefix) return { items: [] }
  return cached(`suggest:${prefix}`, 24 * 60 * 60 * 1000,
    () => runWorker({ op: 'suggest', prefix }))
}))
// 搜索框轮播提示词
app.get('/api/cues', wrap(() => cached('cues', 12 * 60 * 60 * 1000,
  () => runWorker({ op: 'cues' }))))
// 弹幕（按分集）
app.get('/api/danmaku/:episodeId', wrap((req) => {
  const episodeId = req.params.episodeId
  const seriesId = (req.query.seriesId || '').toString()
  const cursor = (req.query.cursor || '').toString()
  const startMs = Number(req.query.startMs || 0) || 0
  return cached(`dm:${episodeId}:${cursor}:${startMs}`, 6 * 60 * 60 * 1000,
    () => runWorker({ op: 'danmaku', seriesId, episodeId, cursor, startMs }))
}))
// 相关推荐（猜你喜欢）
app.get('/api/recommend/:seriesId', wrap((req) => {
  const sid = req.params.seriesId
  if (String(sid).startsWith('vod_')) return { cellTitle: '', sessionId: '', items: [] }
  return cached(`rec:${sid}`, 12 * 60 * 60 * 1000,
    () => runWorker({ op: 'recommend', seriesId: sid }))
}))
// 剧集详情
app.get('/api/series/:seriesId', wrap((req) => {
  const sid = req.params.seriesId
  if (String(sid).startsWith('vod_')) return { id: sid, title: '', heat: 0 }
  return cached(`series:${sid}`, 12 * 60 * 60 * 1000,
    () => runWorker({ op: 'series', seriesId: sid }))
}))
// 短剧排行榜
app.get('/api/rank', wrap((req) => {
  const content = (req.query.content || '').toString()
  const board = (req.query.board || '').toString()
  const cursor = (req.query.cursor || '').toString()
  return cached(`rank:${content}:${board}:${cursor}`, 2 * 60 * 60 * 1000,
    () => runWorker({ op: 'rank', content, board, cursor }))
}))
app.get('/api/episodes/:seriesId', wrap(async (req) => {
  const sid = req.params.seriesId
  const cursor = (req.query.cursor || '').toString()
  if (getStable() && String(sid).startsWith('vod_')) {
    const page = await stableEpisodes(sid)
    noteEpisodeOrder(page && page.items)
    return page
  }
  const page = await cached(`ep:${sid}:${cursor}`, 60 * 60 * 1000,
    () => runWorker({ op: 'episodes', seriesId: sid, cursor }))
  // 记录集数顺序（只记首页 cursor 为空的，序号即集数；翻页的靠后不影响前2集判断）
  if (!cursor) noteEpisodeOrder(page && page.items)
  return page
}))
app.get('/api/play/:episodeId', wrap(async (req, res) => {
  if (isGuestLocked(req, req.params.episodeId)) {
    res.status(403).json({ error: '登录后解锁全部剧集（游客免费试看前2集）', locked: true })
    return
  }
  // 稳定源短剧（vod_ 前缀）：App 端只有 protected=true 才会走 /api/stream 本机 HLS 代理。
  // 这里直接告诉客户端是「已处理流」，实际地址由 /api/stream/vod_xxx 返回改写后的 m3u8。
  if (String(req.params.episodeId).startsWith('vod_')) {
    return { protected: true, streams: [], contentKey: null }
  }
  return runPlayCached(req.params.episodeId)
}))

app.get('/api/stream/:episodeId', wrap(async (req, res) => {
  const epId = safeEpId(req.params.episodeId)
  if (!epId) return res.status(400).json({ error: 'invalid episodeId' })
  if (isGuestLocked(req, epId)) {
    res.status(403).json({ error: '登录后解锁全部剧集（游客免费试看前2集）', locked: true })
    return
  }
  // 稳定源短剧：返回经本机改写过的 HLS 播放列表，分片走 /api/vodseg 代理，
  // 保证 iOS 全程只连本机服务器，不直连第三方 CDN（避免黑屏）。
  if (String(epId).startsWith('vod_')) {
    const cacheKey = `sf:url:${epId}`
    const url = await cached(cacheKey, 60 * 60 * 1000, () => stableM3U8Url(epId))
    await serveHLS(req, res, url)
    return
  }
  // 默认最高画质 1080p；可用 ?q= 指定。缓存按画质分开，避免旧低清缓存串味。
  const quality = safeQuality(req.query.q)
  const cacheFile = path.join(CACHE_DIR, `cg_${epId}_${quality}.mp4`)
  // 双保险：确认解析后路径仍在缓存目录内
  if (!path.resolve(cacheFile).startsWith(path.resolve(CACHE_DIR) + path.sep)) {
    return res.status(400).json({ error: 'invalid cache path' })
  }

  if (!fs.existsSync(cacheFile)) {
    let job = streamJobs.get(cacheFile)
    if (!job) {
      job = (async () => {
      console.log(`[stream] 开始处理 ${epId}`)
      const info = await runPlayCached(epId)
      const streams = info.streams || []
      let dlUrl
      if (!info.protected) {
        const rank = { '360p': 1, '480p': 2, '540p': 3, '720p': 4, '1080p': 5 }
        const s = streams.find((x) => x.definition === quality)
          || streams.slice().sort((a, b) => (rank[b.definition] || 0) - (rank[a.definition] || 0))[0]
          || streams[streams.length - 1]
        if (!s?.url) throw new Error('no stream')
        console.log(`[stream] ${epId}(明流) 选档 ${s.definition}`)
        dlUrl = s.url
      } else {
        // 按画质选：先精确匹配 q，再退回最高档（streams 通常按清晰度升序 360p→1080p）
        const enc = streams.filter((s) => (s.codec || '').startsWith('bytevc'))
        const pool = enc.length ? enc : streams
        const rank = { '360p': 1, '480p': 2, '540p': 3, '720p': 4, '1080p': 5 }
        const byQuality = pool.find((s) => s.definition === quality)
          || pool.slice().sort((a, b) => (rank[b.definition] || 0) - (rank[a.definition] || 0))[0]
          || pool[pool.length - 1]
        if (!byQuality?.url) throw new Error('no stream')
        if (!info.contentKey?.key) throw new Error('no content key')
        dlUrl = byQuality.url
        console.log(`[stream] ${epId} 选档 ${byQuality.definition} (请求 ${quality})`)
      }
      const tmp = cacheFile + (info.protected ? '.enc' : '.tmp')
      await downloadTo(dlUrl, tmp)
      if (info.protected) {
        decryptFile(tmp, info.contentKey.key)
        fs.renameSync(tmp, cacheFile)
      } else {
        fs.renameSync(tmp, cacheFile)
      }
      console.log(`[stream] ${epId} 就绪 ${fs.statSync(cacheFile).size}B`)
      sweepCache()
      return {}
    })().catch((e) => { console.log(`[stream] ${epId} 失败: ${String(e && e.message || e).slice(0, 200)}`); throw e })
      .finally(() => streamJobs.delete(cacheFile))
      streamJobs.set(cacheFile, job)
    }
    const out = await job
    void out
  }

  res.setHeader('Content-Type', 'video/mp4')
  res.setHeader('Accept-Ranges', 'bytes')
  res.setHeader('Cache-Control', 'max-age=86400')
  res.sendFile(cacheFile, { acceptRanges: true }, (err) => { if (err && !res.headersSent) res.status(500).end() })
}))

const PORT = process.env.PORT || 3002
app.listen(PORT, () => {
  console.log(`红果 REST 代理(worker版) 已启动: 0.0.0.0:${PORT}`)
  warmupPools().catch(() => {})   // 后台预热，不阻塞启动
})
