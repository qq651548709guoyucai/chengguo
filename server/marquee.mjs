// 播放器跑马灯配置：JSON 文件存储。公开拉取 + 超级管理员设置。
// App 播放器叠加一层循环滚动字幕，文字/颜色/字号/速度全部后台可配。
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DATA_DIR = path.join(__dirname, 'data')
const FILE = path.join(DATA_DIR, 'marquee.json')
fs.mkdirSync(DATA_DIR, { recursive: true })

const DEFAULT = {
  enabled: true,
  text: '熬夜看短剧 每晚更新',
  speed: 60,          // 滚动速度：每秒移动的像素点数，越大越快
  fontSize: 15,       // 字号
  fontColor: '#ffffff',
  background: '#000000',
  opacity: 0.55,      // 背景透明度 0~1
}

let db
try {
  db = fs.existsSync(FILE) ? { ...DEFAULT, ...JSON.parse(fs.readFileSync(FILE, 'utf8')) } : { ...DEFAULT }
} catch (e) {
  console.error('读取跑马灯配置失败:', e.message)
  db = { ...DEFAULT }
}

function save() {
  const tmp = FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
  fs.renameSync(tmp, FILE)
}
if (!fs.existsSync(FILE)) save()

// 公开接口：App 拉取
export function getMarquee(req, res) {
  res.json({ ...db })
}

// 超级管理员：更新配置
export function updateMarquee(req, res) {
  const b = req.body || {}
  const text = (b.text ?? db.text).toString().trim().replace(/[\r\n]+/g, ' ')
  if (text.length > 80) return res.status(400).json({ error: '文字最多 80 字' })
  const isColor = v => /^#[0-9a-fA-F]{6}$/.test(v || '') || /^[a-zA-Z]+$/.test(v || '')
  // 注意：不能用 `Number(v) || fallback`，因为 0 是合法值（透明度 0 = 全透明）却是 falsy，
  // 会被错误回退成旧值。这里用 nullish 判断，允许 0 正常保存。
  const num = (v, fallback, lo, hi) => {
    if (v === undefined || v === null || v === '') return fallback
    const n = Number(v)
    return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : fallback
  }
  db = {
    enabled: b.enabled === undefined ? db.enabled : !!b.enabled,
    text,
    speed: num(b.speed, db.speed, 10, 300),
    fontSize: num(b.fontSize, db.fontSize, 10, 32),
    fontColor: isColor(b.fontColor) ? b.fontColor : db.fontColor,
    background: isColor(b.background) ? b.background : db.background,
    opacity: num(b.opacity, db.opacity, 0, 1),
  }
  save()
  return { ok: true, ...db }
}
