// 轻量账号系统：JSON 文件存储 + scrypt 密码哈希 + token 鉴权
// 无需数据库依赖，适合小范围自用/分享。数据保存在 data/users.json
import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DATA_DIR = path.join(__dirname, 'data')
const USERS_FILE = path.join(DATA_DIR, 'users.json')
fs.mkdirSync(DATA_DIR, { recursive: true })

// 管理员：用户名 admin，密码首次启动写入（见下方 bootstrap）
let db = { users: [] }
try {
  if (fs.existsSync(USERS_FILE)) db = JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'))
} catch (e) { console.error('读取用户库失败，使用空库:', e.message) }
if (!db.users) db.users = []

let saveTimer = null
function save() {
  // 合并写盘，避免频繁 IO
  if (saveTimer) return
  saveTimer = setTimeout(() => {
    saveTimer = null
    try {
      const tmp = USERS_FILE + '.tmp'
      fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
      fs.renameSync(tmp, USERS_FILE)
    } catch (e) { console.error('保存用户库失败:', e.message) }
  }, 200)
}

function hashPassword(password, salt) {
  salt = salt || crypto.randomBytes(16).toString('hex')
  const hash = crypto.scryptSync(password, salt, 64).toString('hex')
  return `${salt}:${hash}`
}
function verifyPassword(password, stored) {
  try {
    const [salt, hash] = stored.split(':')
    const h = crypto.scryptSync(password, salt, 64).toString('hex')
    return crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(h, 'hex'))
  } catch { return false }
}
function newToken() { return crypto.randomBytes(24).toString('hex') }

// 昵称/头像（内置 emoji 头像，服务端只存标识字符串，不存图片）
const DEFAULT_AVATAR = '🙂'
// 昵称：允许中文/字母/数字/下划线，2~16 字符；空则回退用户名
function cleanNickname(raw, fallback) {
  const s = (raw ?? '').toString().trim().slice(0, 16)
  if (!s) return fallback
  return /^[a-zA-Z0-9_\u4e00-\u9fa5]+$/.test(s) ? s : fallback
}
// 头像：只接受白名单 emoji，防止注入超长/异常内容
const AVATARS = ['🙂','😀','😎','🤩','🥳','😊','😍','🤗','😜','🤔','😴','🥰','😇','🤠','👻','🤖','🐱','🐶','🐼','🦊','🐻','🐯','🦁','🐸','🦄','🐙','🦋','🌸','⭐','🔥','💎','🎮','🍀','🌈','🚀','🏀']
function cleanAvatar(raw) {
  const s = (raw ?? '').toString().trim()
  return AVATARS.includes(s) ? s : DEFAULT_AVATAR
}

function publicUser(u) {
  return {
    id: u.id,
    username: u.username,
    nickname: cleanNickname(u.nickname, u.username),
    avatar: cleanAvatar(u.avatar),
    role: u.role,
    disabled: !!u.disabled,
    createdAt: u.createdAt,
    lastLoginAt: u.lastLoginAt || null,
    stats: {
      favorites: (u.data?.favorites || []).length,
      likes: (u.data?.likedIds || []).length,
      watch: Object.keys(u.data?.progress || {}).length,
    },
  }
}

// 首次启动创建管理员（密码见 ADMIN_PASSWORD 环境变量，默认 admin123456）
function bootstrapAdmin() {
  const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'admin123456'
  if (!db.users.find((u) => u.username === 'admin')) {
    db.users.push({
      id: 'admin',
      username: 'admin',
      role: 'admin',
      disabled: false,
      passwordHash: hashPassword(ADMIN_PASSWORD),
      token: newToken(),
      createdAt: Date.now(),
      lastLoginAt: null,
      data: { favorites: [], likedIds: [], progress: {} },
    })
    save()
    console.log(`[auth] 管理员已创建: admin / ${ADMIN_PASSWORD}（请尽快修改）`)
  }
}
bootstrapAdmin()

function findByToken(token) {
  if (!token) return null
  return db.users.find((u) => u.token === token && !u.disabled) || null
}

// ---------- 对外接口 ----------

export function authMiddleware(req, res, next) {
  const token = (req.headers['x-token'] || req.query.token || '').toString()
  const user = findByToken(token)
  if (!user) return res.status(401).json({ error: '未登录或登录已过期' })
  req.user = user
  next()
}

export function register(req, res) {
  const username = (req.body?.username || '').toString().trim()
  const password = (req.body?.password || '').toString()
  if (username.length < 2 || username.length > 24) return res.status(400).json({ error: '用户名需 2~24 字符' })
  if (password.length < 6 || password.length > 64) return res.status(400).json({ error: '密码需 6~64 位' })
  if (!/^[a-zA-Z0-9_\u4e00-\u9fa5]+$/.test(username)) return res.status(400).json({ error: '用户名只能含字母数字下划线和中文' })
  if (db.users.find((u) => u.username.toLowerCase() === username.toLowerCase())) {
    return res.status(409).json({ error: '用户名已存在' })
  }
  const nickname = cleanNickname(req.body?.nickname, username)
  const avatar = cleanAvatar(req.body?.avatar)
  const user = {
    id: 'u_' + crypto.randomBytes(8).toString('hex'),
    username,
    nickname,
    avatar,
    role: 'user',
    disabled: false,
    passwordHash: hashPassword(password),
    token: newToken(),
    createdAt: Date.now(),
    lastLoginAt: null,
    data: { favorites: [], likedIds: [], progress: {} },
  }
  db.users.push(user)
  save()
  console.log(`[auth] 新用户注册: ${username} (名号: ${nickname})`)
  res.json({ token: user.token, user: publicUser(user) })
}

export function login(req, res) {
  const username = (req.body?.username || '').toString().trim()
  const password = (req.body?.password || '').toString()
  const user = db.users.find((u) => u.username.toLowerCase() === username.toLowerCase())
  if (!user || !verifyPassword(password, user.passwordHash)) {
    return res.status(401).json({ error: '用户名或密码错误' })
  }
  if (user.disabled) return res.status(403).json({ error: '账号已被禁用，请联系管理员' })
  user.token = newToken()          // 每次登录换 token
  user.lastLoginAt = Date.now()
  save()
  console.log(`[auth] 用户登录: ${username}`)
  res.json({ token: user.token, user: publicUser(user) })
}

export function me(req, res) {
  res.json({ user: publicUser(req.user) })
}

// 修改密码：校验原密码，重设新密码；token 保持不变（改完无需重新登录）
export function changePassword(req, res) {
  const oldPassword = (req.body?.oldPassword || '').toString()
  const newPassword = (req.body?.newPassword || '').toString()
  if (newPassword.length < 6 || newPassword.length > 64) {
    return res.status(400).json({ error: '新密码需 6~64 位' })
  }
  if (!verifyPassword(oldPassword, req.user.passwordHash)) {
    return res.status(400).json({ error: '原密码错误' })
  }
  req.user.passwordHash = hashPassword(newPassword)
  save()
  console.log(`[auth] 修改密码: ${req.user.username}`)
  res.json({ ok: true })
}

// 修改个人资料（名号 / 头像），保留其他字段；传空名号则回退用户名
export function updateProfile(req, res) {
  const b = req.body || {}
  const hasNick = Object.prototype.hasOwnProperty.call(b, 'nickname')
  const hasAvatar = Object.prototype.hasOwnProperty.call(b, 'avatar')
  if (hasNick) req.user.nickname = cleanNickname(b.nickname, req.user.username)
  if (hasAvatar) req.user.avatar = cleanAvatar(b.avatar)
  save()
  console.log(`[auth] 修改资料: ${req.user.username} -> ${req.user.nickname}`)
  res.json({ ok: true, user: publicUser(req.user) })
}

// 用户上传自己的数据（整体覆盖）
export function syncData(req, res) {
  const data = req.body?.data
  if (!data || typeof data !== 'object') return res.status(400).json({ error: '数据格式错误' })
  req.user.data = {
    favorites: Array.isArray(data.favorites) ? data.favorites.slice(0, 500) : [],
    likedIds: Array.isArray(data.likedIds) ? data.likedIds.slice(0, 2000) : [],
    progress: (data.progress && typeof data.progress === 'object') ? data.progress : {},
  }
  save()
  res.json({ ok: true })
}

export function getData(req, res) {
  res.json({ data: req.user.data || { favorites: [], likedIds: [], progress: {} } })
}

// ---------- 管理接口（需 admin token）----------

export function adminMiddleware(req, res, next) {
  const token = (req.headers['x-token'] || req.query.token || '').toString()
  const user = db.users.find((u) => u.token === token && u.role === 'admin')
  if (!user) return res.status(403).json({ error: '需要管理员权限' })
  req.admin = user
  next()
}

// 超级管理员（id === 'admin'，即最初的 admin 账号）：公告发布、管理员管理等高危操作
export function superAdminMiddleware(req, res, next) {
  const token = (req.headers['x-token'] || req.query.token || '').toString()
  const user = db.users.find((u) => u.token === token && u.role === 'admin')
  if (!user) return res.status(403).json({ error: '需要管理员权限' })
  if (user.id !== 'admin') return res.status(403).json({ error: '仅超级管理员可操作' })
  req.admin = user
  next()
}

export function adminListUsers(req, res) {
  res.json({ users: db.users.map(publicUser) })
}

export function adminStats(req, res) {
  const total = db.users.length
  const today = new Date(); today.setHours(0, 0, 0, 0)
  const todayNew = db.users.filter((u) => u.createdAt >= today.getTime()).length
  const active = db.users.filter((u) => u.lastLoginAt && u.lastLoginAt >= Date.now() - 7 * 86400_000).length
  const disabled = db.users.filter((u) => u.disabled).length
  res.json({ total, todayNew, active, disabled })
}

export function adminToggleUser(req, res) {
  const id = req.body?.id
  const u = db.users.find((x) => x.id === id)
  if (!u) return res.status(404).json({ error: '用户不存在' })
  if (u.role === 'admin') return res.status(400).json({ error: '不能操作系统管理员' })
  u.disabled = !u.disabled
  if (u.disabled) u.token = ''    // 禁用即失效 token
  save()
  res.json({ ok: true, disabled: u.disabled })
}

export function adminDeleteUser(req, res) {
  const id = req.body?.id
  const u = db.users.find((x) => x.id === id)
  if (!u) return res.status(404).json({ error: '用户不存在' })
  if (u.role === 'admin') return res.status(400).json({ error: '不能删除系统管理员' })
  db.users = db.users.filter((x) => x.id !== id)
  save()
  res.json({ ok: true })
}

// ---------- 管理员管理 ----------

// 列出所有管理员
export function adminListAdmins(req, res) {
  const admins = db.users.filter((u) => u.role === 'admin').map(publicUser)
  res.json({ admins })
}

// 新建管理员账号（管理员专用，可指定初始密码）
export function adminCreateAdmin(req, res) {
  const username = (req.body?.username || '').toString().trim()
  const password = (req.body?.password || '').toString()
  if (username.length < 2 || username.length > 24) return res.status(400).json({ error: '用户名需 2~24 字符' })
  if (password.length < 6 || password.length > 64) return res.status(400).json({ error: '密码需 6~64 位' })
  if (!/^[a-zA-Z0-9_\u4e00-\u9fa5]+$/.test(username)) return res.status(400).json({ error: '用户名只能含字母数字下划线和中文' })
  if (db.users.find((u) => u.username.toLowerCase() === username.toLowerCase())) {
    return res.status(409).json({ error: '用户名已存在' })
  }
  const u = {
    id: 'u_' + crypto.randomBytes(8).toString('hex'),
    username,
    role: 'admin',
    disabled: false,
    passwordHash: hashPassword(password),
    token: newToken(),
    createdAt: Date.now(),
    lastLoginAt: null,
    data: { favorites: [], likedIds: [], progress: {} },
  }
  db.users.push(u)
  save()
  console.log(`[auth] 新建管理员: ${username} (by ${req.admin?.username})`)
  res.json({ admin: publicUser(u) })
}

// 把现有用户提升为管理员
export function adminPromoteUser(req, res) {
  const id = (req.body?.id || '').toString().trim()
  const u = db.users.find((x) => x.id === id)
  if (!u) return res.status(404).json({ error: '用户不存在' })
  if (u.role === 'admin') return res.status(400).json({ error: '该用户已是管理员' })
  u.role = 'admin'
  u.disabled = false
  u.token = u.token || newToken()
  save()
  console.log(`[auth] 提升为管理员: ${u.username} (by ${req.admin?.username})`)
  res.json({ ok: true, admin: publicUser(u) })
}

// 撤销管理员权限（降级为普通用户）
export function adminDemoteAdmin(req, res) {
  const id = (req.body?.id || '').toString().trim()
  if (id === req.admin?.id) return res.status(400).json({ error: '不能撤销自己的管理员权限' })
  const u = db.users.find((x) => x.id === id)
  if (!u) return res.status(404).json({ error: '用户不存在' })
  if (u.role !== 'admin') return res.status(400).json({ error: '该用户不是管理员' })
  const adminCount = db.users.filter((x) => x.role === 'admin').length
  if (adminCount <= 1) return res.status(400).json({ error: '不能撤销最后一个管理员' })
  u.role = 'user'
  save()
  console.log(`[auth] 撤销管理员: ${u.username} (by ${req.admin?.username})`)
  res.json({ ok: true })
}
