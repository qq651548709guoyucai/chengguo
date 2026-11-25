// 去广告水印配置：JSON 文件存储。公开拉取 + 超级管理员设置。
// 转码服务 cleanseg.py 直接读取同目录下的 data/watermark.json（共享挂载）。
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DATA_DIR = path.join(__dirname, 'data')
const FILE = path.join(DATA_DIR, 'watermark.json')
fs.mkdirSync(DATA_DIR, { recursive: true })

const DEFAULT = {
  enabled: true,
  text: '熬夜看短剧 每晚更新',
  fontSize: 40,
  fontColor: 'white',
  boxColor: 'black@0.5',
}

let db
try {
  db = fs.existsSync(FILE) ? { ...DEFAULT, ...JSON.parse(fs.readFileSync(FILE, 'utf8')) } : { ...DEFAULT }
} catch (e) {
  console.error('读取水印配置失败:', e.message)
  db = { ...DEFAULT }
}

function save() {
  const tmp = FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
  fs.renameSync(tmp, FILE)
}
// 首次启动落盘，保证 cleanseg.py 一定读得到
if (!fs.existsSync(FILE)) save()

// 公开接口：App/转码服务读取（含默认值兜底）
export function getWatermark(req, res) {
  res.json({ ...db })
}

// 超级管理员：更新配置
export function updateWatermark(req, res) {
  const b = req.body || {}
  const text = (b.text ?? db.text).toString().trim()
  if (text.length > 60) return res.status(400).json({ error: '文字最多 60 字' })
  // 过滤换行，避免 textfile 多行导致的绘制异常
  const cleanText = text.replace(/[\r\n]+/g, ' ')
  db = {
    enabled: b.enabled === undefined ? db.enabled : !!b.enabled,
    text: cleanText,
    fontSize: Math.min(72, Math.max(20, Number(b.fontSize) || db.fontSize)),
    fontColor: /^[a-zA-Z@0-9.#]+$/.test(b.fontColor || '') ? b.fontColor : db.fontColor,
    boxColor: /^[a-zA-Z@0-9.#]+$/.test(b.boxColor || '') ? b.boxColor : db.boxColor,
  }
  save()
  return { ok: true, ...db }
}
