// 动态页面配置：JSON 文件存储。App 端用原生组件渲染，后台可视化编辑，改完即生效无需更新 App。
// 数据结构：
// {
//   version: 1,
//   pages: [
//     { id, name, sections: [
//         { type: "text"|"banner"|"grid"|"list"|"notice"|"button", title?, subtitle?, text?, columns?,
//           items?: [ { title, cover, subtitle?, action } ] }
//       ] }
//   ]
// }
// action 跳转协议（字符串）：
//   play:<seriesId>        打开短剧播放
//   vod:<vodId>            打开影视详情（当前切到影视 Tab）
//   search:<关键词>         发起搜索
//   tab:<0|1|2|3|4>        切换底部 Tab
//   url:<https://...>      系统浏览器打开外链
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DATA_DIR = path.join(__dirname, 'data')
const FILE = path.join(DATA_DIR, 'pages.json')
fs.mkdirSync(DATA_DIR, { recursive: true })

// 默认示例：4 类区块都给一份，后台可直接改
const DEFAULT = {
  version: 1,
  pages: [
    {
      id: 'discover',
      name: '发现',
      sections: [
        { type: 'text', title: '发现', subtitle: '内容由后台配置，改完即生效' },
        {
          type: 'notice',
          text: '欢迎使用熬夜看短剧 · 后台可随时更换这里的内容',
          action: 'tab:0',
        },
        {
          type: 'button',
          title: '快捷入口',
          items: [
            { title: '去首页', action: 'tab:0' },
            { title: '去影视', action: 'tab:3' },
            { title: '搜短剧', action: 'search:短剧' },
          ],
        },
        {
          type: 'grid',
          title: '网格示例',
          columns: 3,
          items: [],
        },
      ],
    },
  ],
}

let db
try {
  db = fs.existsSync(FILE)
    ? { ...DEFAULT, ...JSON.parse(fs.readFileSync(FILE, 'utf8')) }
    : JSON.parse(JSON.stringify(DEFAULT))
} catch (e) {
  console.error('读取动态页面配置失败:', e.message)
  db = JSON.parse(JSON.stringify(DEFAULT))
}

function save() {
  const tmp = FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
  fs.renameSync(tmp, FILE)
}
if (!fs.existsSync(FILE)) save()

// 公开接口：App 拉取
export function getPages(req, res) {
  res.json(db)
}

// ---------- 输入清洗 ----------
const TYPES = new Set(['text', 'banner', 'grid', 'list', 'notice', 'button'])
const clampStr = (v, max = 200) => (v === undefined || v === null ? '' : String(v).trim().slice(0, max))
const clampNum = (v, fallback, lo, hi) => {
  if (v === undefined || v === null || v === '') return fallback
  const n = Number(v)
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, Math.trunc(n))) : fallback
}
function cleanAction(v) {
  const s = clampStr(v, 500)
  if (!s) return ''
  const [kind, ...rest] = s.split(':')
  const payload = rest.join(':')
  if (kind === 'url') {
    // 只允许 http(s)，杜绝 javascript: 之类
    return /^https?:\/\//i.test(payload) ? s : ''
  }
  if (['play', 'vod', 'search', 'tab'].includes(kind)) return s
  return ''
}
function cleanItem(raw) {
  if (!raw || typeof raw !== 'object') return null
  const action = cleanAction(raw.action)
  const item = {
    title: clampStr(raw.title, 60),
    cover: clampStr(raw.cover, 500),
    subtitle: clampStr(raw.subtitle, 120),
    action,
  }
  if (!item.title && !item.cover && !item.action) return null
  return item
}
function cleanSection(raw) {
  if (!raw || typeof raw !== 'object') return null
  const type = TYPES.has(raw.type) ? raw.type : 'text'
  const sec = {
    type,
    title: clampStr(raw.title, 60),
    subtitle: clampStr(raw.subtitle, 120),
    text: clampStr(raw.text, 300),
    action: cleanAction(raw.action),
  }
  if (type === 'grid' || type === 'list' || type === 'banner' || type === 'button') {
    sec.columns = clampNum(raw.columns, type === 'grid' ? 3 : 1, 1, 4)
    const items = Array.isArray(raw.items) ? raw.items : []
    sec.items = items.slice(0, 60).map(cleanItem).filter(Boolean)
  }
  return sec
}
function cleanPage(raw) {
  if (!raw || typeof raw !== 'object') return null
  const sections = Array.isArray(raw.sections) ? raw.sections : []
  return {
    id: clampStr(raw.id, 40) || ('page_' + Date.now()),
    name: clampStr(raw.name, 20) || '未命名',
    sections: sections.slice(0, 40).map(cleanSection).filter(Boolean),
  }
}

// 超级管理员：整体更新配置
export function updatePages(req, res) {
  const b = req.body || {}
  const rawPages = Array.isArray(b.pages) ? b.pages : []
  if (rawPages.length > 20) return res.status(400).json({ error: '页面最多 20 个' })
  const pages = rawPages.map(cleanPage).filter(Boolean)
  if (pages.length === 0) return res.status(400).json({ error: '至少保留一个页面' })
  db = { version: 1, pages }
  save()
  return { ok: true, ...db }
}
