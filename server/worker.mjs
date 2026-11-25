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
      items: page.items.map((e) => ({ id: String(e.id), title: e.title || '', index: e.index || e.episode_index || null })),
      cursor: page.cursor, hasMore: page.has_more ?? page.hasMore,
    }
    break
  }
  // ===== 以下为红果官方 API 扩展（SDK 已封装，项目此前未接入）=====
  case 'hgFeed': {
    // 红果官方数据源首页：discover 常被匿名风控，改用 shortRank 榜单当发现源（更稳定），
    // 再用 getSeriesBatch 补全集数/封面。返回格式与 /api/feed 一致。
    const rank = await client.shortRank()
    const raw = rank.items || []
    let items = raw.map((it) => ({
      id: String(it.series_id || it.id || ''),
      title: it.title || '',
      coverUrl: it.cover_url || '',
      description: it.heat || it.description || '',
      episodeCount: it.episode_count || 0,
      rank: it.rank || it.position || 0,
    })).filter((x) => x.id)
    // 批量补全详情（集数、简介），失败不影响基础列表
    try {
      const ids = items.slice(0, 20).map((x) => x.id)
      const details = await client.getSeriesBatch(ids)
      const byId = new Map((details || []).map((d) => [String(d.series_id || d.id), d]))
      items = items.map((x) => {
        const d = byId.get(x.id)
        if (!d) return x
        return {
          ...x,
          episodeCount: d.episode_count || x.episodeCount,
          description: d.abstract || d.description || x.description,
          coverUrl: d.cover_url || x.coverUrl,
        }
      })
    } catch (e) { console.error('[hgFeed] batch detail failed:', e.message) }
    result = { items, cursor: '', hasMore: false }
    break
  }
  case 'suggest': {
    // 搜索联想词：输入前缀返回候选词
    const list = await client.suggest(task.prefix || '')
    result = {
      items: (list || []).map((s) => ({ text: s.text || '', keyword: s.keyword || s.text || '', kind: s.kind ?? null })),
    }
    break
  }
  case 'cues': {
    // 搜索框轮播提示词
    result = { words: await client.searchCues() }
    break
  }
  case 'danmaku': {
    // 弹幕：按分集拉取，支持游标翻页
    const page = await client.listDanmaku(task.seriesId, task.episodeId, {
      ...(task.cursor ? { cursor: task.cursor } : {}),
      ...(task.startMs ? { startMs: task.startMs } : {}),
      ...(task.pageSize ? { pageSize: task.pageSize } : {}),
    })
    result = {
      items: (page.items || []).map((d) => ({
        id: String(d.id || ''), text: d.text || '',
        offsetMs: d.offset_ms || 0, createdAt: d.created_at || '',
        likes: d.likes || 0, plusOnes: d.plus_ones || 0,
      })),
      startMs: page.start_ms || 0, endMs: page.end_ms || 0,
      total: page.total || 0, cursor: page.cursor || '', hasMore: page.has_more ?? page.hasMore ?? false,
    }
    break
  }
  case 'recommend': {
    // 相关推荐：看完一部剧的「猜你喜欢」
    const r = await client.seriesRecommend(task.seriesId)
    result = {
      cellTitle: r.cell_title || '', sessionId: r.session_id || '',
      items: (r.items || []).map(pickSeries),
    }
    break
  }
  case 'series': {
    // 剧集详情：热度、简介、集数、演员等
    const s = await client.getSeries(task.seriesId)
    result = {
      ...pickSeries(s),
      heat: s.heat || 0, status: s.status ?? null, payType: s.pay_type ?? null,
      contentType: s.content_type ?? null, platform: s.platform ?? null,
      categories: s.categories || [], tags: s.tags || [],
      publishAt: s.publish_at || '', rating: s.rating ?? null,
    }
    break
  }
  case 'rank': {
    // 短剧排行榜：content/board 可选，缺省用内置短剧榜
    const r = await client.shortRank({
      ...(task.content ? { content: task.content } : {}),
      ...(task.board ? { board: task.board } : {}),
      ...(task.cursor ? { cursor: task.cursor } : {}),
    })
    result = {
      content: r.content || '', board: r.board || '', version: r.version || '',
      hasMore: r.has_more ?? r.hasMore ?? false,
      contents: (r.contents || []).map((c) => ({ content: c.content || '', boards: c.boards || [] })),
      items: (r.items || []).map((it) => ({
        id: String(it.series_id || it.id || ''),
        title: it.title || '', coverUrl: it.cover_url || '',
        rank: it.rank || it.position || 0, change: it.change || null,
        heat: it.heat || '', episodeCount: it.episode_count || 0,
      })),
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

// 修复 M1：管道下 stdout 是异步写，直接 process.exit 会截断未刷新的数据，
// 导致父进程 JSON.parse 失败并反复重试。等 drain 回调后再退出。
const output = JSON.stringify(result)
if (process.stdout.write(output)) {
  process.exit(0)
} else {
  process.stdout.once('drain', () => process.exit(0))
}
