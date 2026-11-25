// openhongguo 上游更新监控
// 监控源：npm registry（版本）+ git ls-remote（tag / main 分支 commit）
// 每次运行对比 data/upstream-state.json；首次运行仅建立基线。
// 有变化时 stdout 打印 "ALERT:" 开头的变化摘要，并自动写入 App 公告。
import { execFileSync } from 'child_process'
import fs from 'fs'
import path from 'path'
import crypto from 'crypto'
import { fileURLToPath } from 'url'
import { withFileLock } from './filelock.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const STATE = path.join(__dirname, 'data', 'upstream-state.json')
const ANNOUNCE = path.join(__dirname, 'data', 'announcements.json')
fs.mkdirSync(path.join(__dirname, 'data'), { recursive: true })

function sh(cmd, args) {
  return execFileSync(cmd, args, { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'] })
}
function shRetry(cmd, args, tries = 3) {
  let last
  for (let i = 0; i < tries; i++) {
    try { return sh(cmd, args) } catch (e) { last = e }
  }
  throw last
}

function checkNpm() {
  const raw = shRetry('curl', ['-sL', '--max-time', '30', 'https://registry.npmjs.org/openhongguo'])
  const d = JSON.parse(raw)
  return {
    latest: d?.['dist-tags']?.latest || null,
    versions: Object.keys(d?.versions || {}),
  }
}

function checkGit() {
  const raw = shRetry('git', ['-c', 'http.lowSpeedLimit=0', '-c', 'http.lowSpeedTime=999999', 'ls-remote', '--tags', '--heads', 'https://github.com/beilunyang/openhongguo.git'], 4)
  const refs = {}
  for (const line of raw.trim().split('\n')) {
    if (!line.trim()) continue
    const [sha, ref] = line.split('\t')
    // 跳过 annotated tag 的 ^{} 解引用行，保留常规 tag 和 heads
    if (!ref || ref.endsWith('^{}')) continue
    refs[ref] = sha
  }
  return refs
}

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE, 'utf8')) } catch { return null }
}
function saveState(s) {
  const tmp = STATE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2))
  fs.renameSync(tmp, STATE)
}

function pushAnnouncement(title, content) {
  // 修复 M7：与 server 端共用跨进程锁，整段「读-判重-改-写」互斥，
  // 避免定时监控与管理员操作互相覆盖公告。
  withFileLock('announcements', () => {
    let db = { announcements: [] }
    try { if (fs.existsSync(ANNOUNCE)) db = JSON.parse(fs.readFileSync(ANNOUNCE, 'utf8')) } catch {}
    if (!db.announcements) db.announcements = []
    // 避免重复推送同一内容
    if (db.announcements.some(a => a.title === title && a.content === content)) return
    db.announcements.unshift({
      id: 'a_' + crypto.randomBytes(8).toString('hex'),
      title, content, pinned: true, author: 'system',
      createdAt: Date.now(), updatedAt: null,
    })
    const tmp = ANNOUNCE + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify(db, null, 2))
    fs.renameSync(tmp, ANNOUNCE)
  })
}

let npmData, gitRefs
try {
  npmData = checkNpm()
  gitRefs = checkGit()
} catch (e) {
  console.log('CHECK_ERROR: ' + e.message)
  process.exit(1)
}

const now = {
  checkedAt: new Date().toISOString(),
  npmLatest: npmData.latest,
  npmVersions: npmData.versions,
  refs: gitRefs,
}
const prev = loadState()
if (!prev) {
  saveState(now)
  console.log(`BASELINE: npm=${npmData.latest} tags=${Object.keys(gitRefs).filter(r => r.startsWith('refs/tags/')).join(',')} main=${(gitRefs['refs/heads/main'] || '').slice(0, 10)}`)
  process.exit(0)
}

const alerts = []
// npm 新版本
if (npmData.latest && prev.npmLatest && npmData.latest !== prev.npmLatest) {
  alerts.push(`npm 最新版: ${prev.npmLatest} → ${npmData.latest}`)
}
const newVersions = npmData.versions.filter(v => !(prev.npmVersions || []).includes(v))
if (newVersions.length) alerts.push(`npm 新增版本: ${newVersions.join(', ')}`)
// git 新 tag
const prevTags = prev.refs || {}
for (const [ref, sha] of Object.entries(gitRefs)) {
  if (!ref.startsWith('refs/tags/')) continue
  if (!(ref in prevTags)) alerts.push(`新标签: ${ref.replace('refs/tags/', '')} (${sha.slice(0, 10)})`)
  else if (prevTags[ref] !== sha) alerts.push(`标签更新: ${ref.replace('refs/tags/', '')} → ${sha.slice(0, 10)}`)
}
// main 分支新提交
const oldMain = prevTags['refs/heads/main']
const newMain = gitRefs['refs/heads/main']
if (oldMain && newMain && oldMain !== newMain) alerts.push(`main 分支有新提交: ${oldMain.slice(0, 10)} → ${newMain.slice(0, 10)}`)

saveState(now)

if (!alerts.length) {
  console.log(`NO_CHANGE: npm=${npmData.latest} main=${(newMain || '').slice(0, 10)} (${now.checkedAt})`)
  process.exit(0)
}

const summary = alerts.join('\n- ')
console.log('ALERT:\n- ' + summary)
try {
  pushAnnouncement(
    '短剧播放内核有新动态',
    `检测到 openhongguo 上游更新：\n- ${summary}\n\n可重新构建 App 尝试修复短剧播放。`
  )
  console.log('ANNOUNCE: 已写入 App 公告')
} catch (e) {
  console.log('ANNOUNCE_ERROR: ' + e.message)
}
