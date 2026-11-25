// 评论系统：JSON 文件存储，支持主评论 + 回复，用户删自己 / 管理员删任意
import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DATA_DIR = path.join(__dirname, 'data')
const COMMENTS_FILE = path.join(DATA_DIR, 'comments.json')
fs.mkdirSync(DATA_DIR, { recursive: true })

let db = { comments: [] }
try {
  if (fs.existsSync(COMMENTS_FILE)) db = JSON.parse(fs.readFileSync(COMMENTS_FILE, 'utf8'))
} catch (e) { console.error('读取评论库失败:', e.message) }
if (!db.comments) db.comments = []

let saveTimer = null
function writeNow() {
  const tmp = COMMENTS_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
  fs.renameSync(tmp, COMMENTS_FILE)
}
function save() {
  if (saveTimer) return
  saveTimer = setTimeout(() => {
    saveTimer = null
    try { writeNow() } catch (e) { console.error('保存评论失败:', e.message) }
  }, 200)
}
// 修复 L1：退出时强制刷盘，避免 200ms 窗口内丢评论
process.on('exit', () => {
  if (!saveTimer) return
  clearTimeout(saveTimer)
  saveTimer = null
  try { writeNow() } catch (e) { console.error('退出刷盘失败:', e.message) }
})

function pub(c) {
  return {
    id: c.id,
    seriesId: c.seriesId,
    seriesTitle: c.seriesTitle || '',
    userId: c.userId,
    username: c.username,
    role: c.role || 'user',
    text: c.text,
    parentId: c.parentId || null,
    replyTo: c.replyTo || null,
    createdAt: c.createdAt,
  }
}

// 发布评论（需登录）。parentId 为空=主评论；否则为回复，replyTo 带被回复用户名
export function postComment(req, res) {
  const text = (req.body?.text || '').toString().trim()
  const seriesId = (req.body?.seriesId || '').toString().trim()
  const seriesTitle = (req.body?.seriesTitle || '').toString().trim().slice(0, 80)
  const parentId = (req.body?.parentId || '').toString().trim() || null
  if (!text) return res.status(400).json({ error: '评论内容不能为空' })
  if (text.length > 500) return res.status(400).json({ error: '评论最多 500 字' })
  if (!seriesId) return res.status(400).json({ error: '缺少剧集标识' })

  let replyTo = null
  if (parentId) {
    const parent = db.comments.find((c) => c.id === parentId)
    if (parent) replyTo = parent.username
  }

  const c = {
    id: 'c_' + crypto.randomBytes(8).toString('hex'),
    seriesId,
    seriesTitle,
    userId: req.user.id,
    username: req.user.username,
    role: req.user.role || 'user',
    text,
    parentId,
    replyTo,
    createdAt: Date.now(),
  }
  db.comments.push(c)
  save()
  res.json({ comment: pub(c) })
}

// 按剧拉取评论（主评论 + 其回复，按时间正序）
export function listComments(req, res) {
  const seriesId = (req.query.seriesId || '').toString().trim()
  if (!seriesId) return res.status(400).json({ error: '缺少剧集标识' })
  const list = db.comments.filter((c) => c.seriesId === seriesId).sort((a, b) => a.createdAt - b.createdAt)
  res.json({ comments: list.map(pub) })
}

// 修复 L2：递归收集所有子孙 id，避免删主评论后留下孤儿孙回复
function collectDescendantIds(id) {
  const ids = new Set([id])
  let changed = true
  while (changed) {
    changed = false
    for (const c of db.comments) {
      if (c.parentId && ids.has(c.parentId) && !ids.has(c.id)) {
        ids.add(c.id)
        changed = true
      }
    }
  }
  return ids
}

// 删除评论：本人或管理员
export function deleteComment(req, res) {
  const id = (req.body?.id || '').toString().trim()
  const c = db.comments.find((x) => x.id === id)
  if (!c) return res.status(404).json({ error: '评论不存在' })
  const isAdmin = req.user.role === 'admin'
  if (!isAdmin && c.userId !== req.user.id) return res.status(403).json({ error: '只能删除自己的评论' })
  const ids = collectDescendantIds(id)
  db.comments = db.comments.filter((x) => !ids.has(x.id))
  save()
  res.json({ ok: true })
}

// 管理员：列出全部评论
export function adminListComments(req, res) {
  const list = [...db.comments].sort((a, b) => b.createdAt - a.createdAt).slice(0, 1000)
  res.json({ comments: list.map(pub) })
}

// 管理员：删除任意评论（adminMiddleware 设置的是 req.admin）
export function adminDeleteComment(req, res) {
  const id = (req.body?.id || '').toString().trim()
  const c = db.comments.find((x) => x.id === id)
  if (!c) return res.status(404).json({ error: '评论不存在' })
  const ids = collectDescendantIds(id)
  db.comments = db.comments.filter((x) => !ids.has(x.id))
  save()
  res.json({ ok: true })
}
