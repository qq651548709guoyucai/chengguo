// 公告系统：JSON 文件存储。公开拉取 + 管理员增删改。
import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { withFileLock } from './filelock.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DATA_DIR = path.join(__dirname, 'data')
const FILE = path.join(DATA_DIR, 'announcements.json')
fs.mkdirSync(DATA_DIR, { recursive: true })

// 修复 M7：公告文件会被 server 与 watch-upstream 两个进程同时写。
// 不再持有长期内存副本——每次读/写都在跨进程锁内从磁盘 reload，
// 否则 server 的旧内存 db 整写会覆盖监控脚本刚推入的公告。
function load() {
  try {
    if (fs.existsSync(FILE)) {
      const d = JSON.parse(fs.readFileSync(FILE, 'utf8'))
      return d && Array.isArray(d.announcements) ? d : { announcements: [] }
    }
  } catch (e) { console.error('读取公告库失败:', e.message) }
  return { announcements: [] }
}
function write(db) {
  const tmp = FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
  fs.renameSync(tmp, FILE)
}
// 在锁内「读-改-写」，保证与 watch-upstream.mjs 互斥
function mutate(fn) {
  return withFileLock('announcements', () => {
    const db = load()
    const ret = fn(db)
    write(db)
    return ret
  })
}

function pub(a) {
  return {
    id: a.id,
    title: a.title || '',
    content: a.content || '',
    pinned: !!a.pinned,
    createdAt: a.createdAt,
    updatedAt: a.updatedAt || null,
  }
}

// 公开：拉取全部公告（置顶在前，其次按时间倒序）
export function listAnnouncements(req, res) {
  const list = [...load().announcements].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
    return b.createdAt - a.createdAt
  })
  res.json({ announcements: list.map(pub) })
}

// 管理员：列出全部（同样排序）
export function adminListAnnouncements(req, res) {
  const list = [...load().announcements].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
    return b.createdAt - a.createdAt
  })
  res.json({ announcements: list.map(pub) })
}

function validate(body) {
  const title = (body?.title || '').toString().trim()
  const content = (body?.content || '').toString().trim()
  const pinned = !!body?.pinned
  if (!title) return { error: '标题不能为空' }
  if (title.length > 80) return { error: '标题最多 80 字' }
  if (!content) return { error: '内容不能为空' }
  if (content.length > 5000) return { error: '内容最多 5000 字' }
  return { title, content, pinned }
}

// 管理员：新增
export function addAnnouncement(req, res) {
  const v = validate(req.body)
  if (v.error) return res.status(400).json({ error: v.error })
  const a = {
    id: 'a_' + crypto.randomBytes(8).toString('hex'),
    title: v.title,
    content: v.content,
    pinned: v.pinned,
    author: req.admin?.username || 'admin',
    createdAt: Date.now(),
  }
  mutate((db) => { db.announcements.push(a) })
  res.json({ announcement: pub(a) })
}

// 管理员：编辑
export function updateAnnouncement(req, res) {
  const id = (req.body?.id || '').toString().trim()
  const v = validate(req.body)
  if (v.error) return res.status(400).json({ error: v.error })
  const a = mutate((db) => {
    const found = db.announcements.find((x) => x.id === id)
    if (!found) return null
    found.title = v.title
    found.content = v.content
    found.pinned = v.pinned
    found.updatedAt = Date.now()
    return found
  })
  if (!a) return res.status(404).json({ error: '公告不存在' })
  res.json({ announcement: pub(a) })
}

// 管理员：删除
export function deleteAnnouncement(req, res) {
  const id = (req.body?.id || '').toString().trim()
  const removed = mutate((db) => {
    const before = db.announcements.length
    db.announcements = db.announcements.filter((x) => x.id !== id)
    return db.announcements.length < before
  })
  if (!removed) return res.status(404).json({ error: '公告不存在' })
  res.json({ ok: true })
}
