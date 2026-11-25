// 跨进程文件锁（修复 M7：公告文件多进程写竞态）
// 利用 fs.mkdirSync 的原子性：目录创建成功即拿到锁，EEXIST 表示锁被占用。
// 带超时与陈旧锁回收（进程崩溃遗留的锁目录）。
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const LOCK_ROOT = path.join(__dirname, 'data', '.locks')
fs.mkdirSync(LOCK_ROOT, { recursive: true })

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

export function withFileLock(key, fn, { timeoutMs = 5000, staleMs = 15000 } = {}) {
  const lockDir = path.join(LOCK_ROOT, String(key).replace(/[^a-zA-Z0-9_-]/g, '_'))
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      fs.mkdirSync(lockDir)
      break // 拿到锁
    } catch (e) {
      if (e.code !== 'EEXIST') throw e
      // 陈旧锁回收：锁目录 mtime 停在获取锁时刻，超过 staleMs 视为崩溃遗留
      try {
        const st = fs.statSync(lockDir)
        if (Date.now() - st.mtimeMs > staleMs) {
          fs.rmSync(lockDir, { recursive: true, force: true })
          continue
        }
      } catch {}
      if (Date.now() >= deadline) throw new Error('获取文件锁超时: ' + key)
      sleepSync(20)
    }
  }
  try {
    return fn()
  } finally {
    try { fs.rmSync(lockDir, { recursive: true, force: true }) } catch {}
  }
}
