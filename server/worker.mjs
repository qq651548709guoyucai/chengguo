// 一次性 SDK worker：主进程 fork 本文件执行单个 SDK 调用，
// 卡死/挂起只会影响这个子进程（被主进程超时强杀），绝不阻塞服务。
// 用法：stdin 传入 {"op": "...", ...}，stdout 输出 JSON 结果。
import { createClient } from 'openhongguo'
import fs from 'fs'

// 硬性自杀兜底
setTimeout(() => { console.error('worker self-timeout'); process.exit(3) }, 40_000).unref()

const task = JSON.parse(fs.readFileSync(0, 'utf8'))

// 播放取址必须用「修复版 wasm 的内置签名」（v04.06.04 常量，已在 dist/openhongguo.wasm 中）。
// 2026-11-24 凌晨验证：走 signer 服务签名会被拒（ANONYMOUS_LIMITED），
// 必须用这个手工编译的修复版 wasm + 内置签名（不设 signerUrl）才能取到 5 档清晰度。
// 注意：不要用 npm install 覆盖 node_modules/openhongguo，会冲掉修复版 wasm。
//       修复版原件备份在 /root/openhongguo-fixed.wasm 与 /root/wasm_exec-new.js。
const client = await createClient({
  retryAttempts: 3,
  deviceResets: 5,
  ...(process.env.OHG_API_ORIGIN ? { apiOrigin: process.env.OHG_API_ORIGIN } : {}),
})

const pickSeries = (s) => ({
  id: String(s.id),
  title: s.title || '',
  coverUrl: s.cover_url || s.coverUrl || '',
  description: s.abstract || s.description || '',
  episodeCount: s.episode_count || s.episodeCount || 0,
})
const pageOut = (page) => ({
  items: page.items.map(pickSeries),
  episodes: undefined,
  cursor: page.cursor, hasMore: page.has_more ?? page.hasMore,
})

let result
switch (task.op) {
  case 'feed':
    result = pageOut(await client.discover())
    break
  case 'feedByType': {
    // type: real(真人剧) / comic(漫剧) / ai(AI剧) / film(影视剧)
    const genreMap = {
      real: 'short_play', comic: 'comic_series', ai: 'ai_series', film: 'long_video',
    }
    const genre = genreMap[task.type] || 'short_play'
    const page = await client.shortFilter({
      selections: { genre: [genre] },
      ...(task.cursor ? { cursor: task.cursor } : {}),
    })
    result = pageOut(page)
    break
  }
  case 'search':
    result = pageOut(await client.search(task.q))
    break
  case 'hot': {
    const hot = await client.hotSearch()
    const words = []
    const seen = new Set()
    const items = []
    const addItem = (it, boardName) => {
      if (!it || !it.series_id || seen.has(it.series_id)) return
      seen.add(it.series_id)
      items.push({
        id: String(it.series_id),
        title: it.title || '',
        coverUrl: it.cover_url || '',
        description: it.search_score || it.heat || '',
        episodeCount: it.episode_count || 0,
        rank: it.position || items.length + 1,
        tag: it.tag || '',
        board: boardName || '',
      })
    }
    for (const g of hot.guesses || []) { addItem(g, '猜你想搜'); if (g.title) words.push(g.title) }
    for (const b of hot.boards || []) {
      for (const it of b.items || []) { addItem(it, b.name || '热搜榜'); if (it.title) words.push(it.title) }
    }
    result = { words: [...new Set(words)].slice(0, 15), items: items.slice(0, 30) }
    break
  }
  case 'episodes': {
    const page = await client.listEpisodes(task.seriesId, task.cursor ? { cursor: task.cursor } : {})
    result = {
      // 用 ?? 而非 ||：index=0（第一集）是合法值，用 || 会被误判为空
      items: page.items.map((e) => ({ id: String(e.id), title: e.title || '', index: e.index ?? e.episode_index ?? null })),
      cursor: page.cursor, hasMore: page.has_more ?? page.hasMore,
    }
    break
  }
  case 'play': {
    const r = await client.resolvePlayback(task.episodeId)
    const p = r.playback || {}
    result = {
      protected: !!p.protected,
      streams: (p.streams || []).map((s) => ({ codec: s.codec || '', definition: s.definition || '', url: s.url })),
      contentKey: r.contentKey ? { key: r.contentKey.key || r.contentKey } : null,
      contentKeyError: r.contentKeyError || null,
    }
    break
  }
  default:
    throw new Error(`unknown op ${task.op}`)
}

process.stdout.write(JSON.stringify(result))
process.exit(0)
