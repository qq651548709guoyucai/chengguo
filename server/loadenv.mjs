// .env 预加载模块：必须在任何读取 process.env 的模块之前 import。
// ES Module 的依赖按 import 声明顺序求值，把它放在 server.mjs 第一个 import 即可保证生效。
// Node 原生实现，无需 dotenv。已有环境变量优先于 .env。
import fs from 'node:fs'
try {
  const envPath = new URL('./.env', import.meta.url)
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
      const s = line.trim()
      if (!s || s.startsWith('#')) continue
      const i = s.indexOf('=')
      if (i < 0) continue
      const k = s.slice(0, i).trim()
      const v = s.slice(i + 1).trim()
      if (k && process.env[k] === undefined) process.env[k] = v
    }
    console.log('[config] 已加载 .env')
  } else {
    console.log('[config] 未找到 .env，使用环境变量/默认值')
  }
} catch (e) { console.error('[config] 读取 .env 失败:', e.message) }
