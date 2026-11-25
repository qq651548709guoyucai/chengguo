// CENC (cenc:aes-ctr) 解密器 — Node 版
// 红果加密分集：全样本 AES-128-CTR + bytevc1/2(H.265) fourcc 伪装
// 算法与已验证的 Python PoC / Swift 版一致：
//   - IV 8 字节，放在 16 字节计数器高 64 位，低 64 位从 0 计数
//   - stsd 补丁：encv/enca -> frma 原编码；sinf box 类型改 free（大小不变）
import { createDecipheriv } from 'crypto'
import fs from 'fs'

function findPattern(buf, start, end, pat) {
  outer: for (let i = start; i <= end - pat.length; i++) {
    for (let k = 0; k < pat.length; k++) if (buf[i + k] !== pat[k]) continue outer
    return i
  }
  return -1
}

function u32(buf, o) { return buf.readUInt32BE(o) }

// box 遍历
function walk(buf, start, end) {
  const out = []
  let i = start
  while (i + 8 <= end) {
    let size = u32(buf, i)
    const type = buf.toString('ascii', i + 4, i + 8)
    const s = size < 8 ? (end - i) : size
    out.push({ type, offset: i, size: s, contentStart: i + 8 })
    i += s
    if (s < 8) break
  }
  return out
}

function tencIVSize(buf, stsd) {
  const idx = findPattern(buf, stsd.offset, stsd.offset + stsd.size, Buffer.from('tenc'))
  if (idx < 0) return 8
  // 不同封装器 tenc 内部布局有差异（reserved 字段宽度不同），
  // 在常见偏移范围里找第一个合法的 IV size（8 或 16）
  for (let d = 8; d <= 16; d++) {
    const v = buf[idx + d]
    if (v === 8 || v === 16) return v
  }
  return 8
}

export function decryptMp4Buffer(buf, keyHex) {
  const key = Buffer.from(keyHex, 'hex')
  if (key.length !== 16) throw new Error('bad key')

  const top = walk(buf, 0, buf.length)
  const moov = top.find((b) => b.type === 'moov')
  if (!moov) throw new Error('no moov')
  const moovEnd = moov.offset + moov.size

  const traks = walk(buf, moov.contentStart, moovEnd).filter((b) => b.type === 'trak')

  for (const trak of traks) {
    const trakChildren = walk(buf, trak.contentStart, trak.offset + trak.size)
    const mdia = trakChildren.find((b) => b.type === 'mdia')
    if (!mdia) continue
    const mdiaChildren = walk(buf, mdia.contentStart, mdia.offset + mdia.size)
    const minf = mdiaChildren.find((b) => b.type === 'minf')
    if (!minf) continue
    const minfChildren = walk(buf, minf.contentStart, minf.offset + minf.size)
    const stbl = minfChildren.find((b) => b.type === 'stbl')
    if (!stbl) continue
    const boxes = walk(buf, stbl.contentStart, stbl.offset + stbl.size)
    const dict = Object.fromEntries(boxes.map((b) => [b.type, b]))
    // 修复 M3：co64 轨道此前因取不到 stco 被整条跳过（大文件 >4GB 花屏）。
    // stco 与 co64 都是 chunk offset box，只是偏移宽度不同。
    const stco = dict.stco || dict.co64
    const { stsd, stsz, stsc, senc } = dict
    if (!stsd || !stsz || !stco || !stsc || !senc) continue

    // 样本大小
    const defaultSize = u32(buf, stsz.contentStart + 4)
    const sampleCount = u32(buf, stsz.contentStart + 8)
    const sizes = []
    if (defaultSize > 0) {
      for (let i = 0; i < sampleCount; i++) sizes.push(defaultSize)
    } else {
      for (let i = 0; i < sampleCount; i++) sizes.push(u32(buf, stsz.contentStart + 12 + 4 * i))
    }

    // chunk 偏移：按实际 box 类型决定 4 字节(stco) 还是 8 字节(co64) 解析
    const isCo64 = stco.type === 'co64'
    const chunkCount = u32(buf, stco.contentStart + 4)
    const chunks = []
    for (let i = 0; i < chunkCount; i++) {
      chunks.push(isCo64 ? Number(buf.readBigUInt64BE(stco.contentStart + 8 + 8 * i))
                         : u32(buf, stco.contentStart + 8 + 4 * i))
    }

    // stsc 展开
    const runCount = u32(buf, stsc.contentStart + 4)
    const runs = []
    for (let i = 0; i < runCount; i++) {
      runs.push([u32(buf, stsc.contentStart + 8 + 12 * i), u32(buf, stsc.contentStart + 12 + 12 * i)])
    }
    const offsets = []
    let si = 0
    for (let ri = 0; ri < runs.length; ri++) {
      const [firstChunk, spc] = runs[ri]
      const nextFc = ri + 1 < runs.length ? runs[ri + 1][0] : chunkCount + 1
      let c = firstChunk
      while (c < nextFc && c <= chunkCount) {
        let pos = chunks[c - 1]
        for (let k = 0; k < spc; k++) {
          if (si >= sampleCount) break
          offsets.push(pos)
          pos += sizes[si]
          si++
        }
        c++
      }
    }
    if (si !== sampleCount || offsets.length !== sampleCount) continue

    // senc 条目
    const ivSize = tencIVSize(buf, stsd)
    const verFlags = u32(buf, senc.offset + 8)
    const flags = verFlags & 0xffffff
    const cnt = u32(buf, senc.offset + 12)
    let j = senc.offset + 16
    const entries = []
    for (let n = 0; n < cnt; n++) {
      const iv = buf.slice(j, j + ivSize)
      j += ivSize
      const subs = []
      if (flags & 2) {
        const m = buf.readUInt16BE(j); j += 2
        for (let k = 0; k < m; k++) {
          const cl = buf.readUInt16BE(j)
          const en = buf.readUInt16BE(j + 2)
          j += 4
          subs.push([cl, en])
        }
      }
      entries.push([iv, subs])
    }
    if (entries.length !== sampleCount) continue

    // 解密全部样本（原地）
    // 修复 M2：AES-CTR 计数器必须在同一个 sample 内跨 subsample 连续。
    // 此前每个加密 subsample 都用初始 IV 新建 decipher，导致第 2 段起解密错乱（花屏）。
    // 正确做法：每个 sample 只建一个 decipher，clear 段照样 update 以推进计数器，
    // 但丢弃其明文（保留原始明文），只有 encrypt 段把解密结果写回。
    for (let i = 0; i < sampleCount; i++) {
      const [iv, subs] = entries[i]
      const o = offsets[i], sz = sizes[i]
      const ivUse = iv.length > 16 ? iv.subarray(0, 16) : iv
      const ctrIv = Buffer.concat([ivUse, Buffer.alloc(16 - ivUse.length)])  // 低 64 位补 0
      // 单条 decipher 贯穿整个 sample，计数器连续递增
      const dec = createDecipheriv('aes-128-ctr', key, ctrIv)
      if (subs.length === 0) {
        const src = buf.subarray(o, o + sz)
        src.set(dec.update(src))
        dec.final()
      } else {
        let p = o
        for (const [cl, en] of subs) {
          if (cl > 0) {
            // clear 段：喂给 decipher 推进计数器，明文不写回（本来就是明文）
            dec.update(buf.subarray(p, p + cl))
            p += cl
          }
          if (en > 0) {
            const src = buf.subarray(p, p + en)
            src.set(dec.update(src))
            p += en
          }
        }
        dec.final()
      }
    }

    // stsd 补丁（鲁棒版）：在每个 sample entry 范围内直接搜 sinf/frma，
    // 不依赖固定 header 长度或子 box size 遍历（某些封装的 sinf 前有非标准 box 会让遍历提前 break）。
    const entryCount = u32(buf, stsd.contentStart + 4)
    let e = stsd.contentStart + 8
    for (let n = 0; n < entryCount; n++) {
      if (e + 8 > buf.length) break
      const esz = u32(buf, e)
      if (esz < 8 || e + esz > buf.length) break
      const fmt = buf.toString('ascii', e + 4, e + 8)
      // 只处理加密马甲 encv/enca（或已是明文的跳过）
      if (fmt === 'encv' || fmt === 'enca') {
        const sinf = findPattern(buf, e, e + esz, Buffer.from('sinf'))
        const frma = findPattern(buf, e, e + esz, Buffer.from('frma'))
        if (sinf >= 0 && frma >= 0) {
          buf.copy(buf, e + 4, frma + 4, frma + 8)          // fourcc: encv/enca -> 原始编码(hvc1/avc1/mp4a)
          buf.write('free', sinf + 4, 4, 'ascii')            // sinf -> free（大小不变）
        }
      }
      e += esz
    }
  }

  return buf
}

/// 解密文件：读入 -> 解密 -> 写回（短剧单集几十 MB，内存可承受）
export function decryptFile(path, keyHex) {
  const buf = fs.readFileSync(path)
  decryptMp4Buffer(buf, keyHex)
  fs.writeFileSync(path, buf)
}
