// 评论系统：JSON 文件存储，支持主评论 + 回复，用户删自己 / 管理员删任意
import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { publicUserById } from './auth.mjs'
import { checkComment } from './guard.mjs'

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
function save() {
  if (saveTimer) return
  saveTimer = setTimeout(() => {
    saveTimer = null
    try {
      const tmp = COMMENTS_FILE + '.tmp'
      fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
      fs.renameSync(tmp, COMMENTS_FILE)
    } catch (e) { console.error('保存评论失败:', e.message) }
  }, 200)
}

function pub(c) {
  // 关联用户实时资料：改名号/头像后评论区同步更新；用户不存在则回退评论里的旧 username
  const u = publicUserById(c.userId)
  return {
    id: c.id,
    seriesId: c.seriesId,
    seriesTitle: c.seriesTitle || '',
    userId: c.userId,
    username: c.username,
    nickname: u?.nickname || c.username || '',
    avatar: u?.avatar || '🙂',
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
  // 内容审核：管理员可免审，普通用户拦截广告/QQ号等引流内容
  if (req.user.role !== 'admin') {
    const r = checkComment(text)
    if (r.blocked) return res.status(400).json({ error: r.reason })
  }

  let replyTo = null
  if (parentId) {
    const parent = db.comments.find((c) => c.id === parentId)
    if (parent) {
      // 回复对象显示实时名号（找不到则回退旧 username）
      const pu = publicUserById(parent.userId)
      replyTo = pu?.nickname || parent.username
    }
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

// 删除评论：本人或管理员
export function deleteComment(req, res) {
  const id = (req.body?.id || '').toString().trim()
  const c = db.comments.find((x) => x.id === id)
  if (!c) return res.status(404).json({ error: '评论不存在' })
  const isAdmin = req.user.role === 'admin'
  if (!isAdmin && c.userId !== req.user.id) return res.status(403).json({ error: '只能删除自己的评论' })
  db.comments = db.comments.filter((x) => x.id !== id && x.parentId !== id)  // 连同其回复一起删
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
  db.comments = db.comments.filter((x) => x.id !== id && x.parentId !== id)
  save()
  res.json({ ok: true })
}
