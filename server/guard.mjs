// 内容审核：拦截名号/用户名/评论里的广告、QQ号、微信等引流内容
// 纯字符串规则，无第三方依赖。命中返回 { blocked, reason }，否则 { blocked: false }

// 全角转半角 + 去空白/零宽/常见分隔符，防止「微 信」「Q-Q」「1 2 3 4 5」绕过
function tight(s) {
  return (s ?? '').toString()
    .replace(/[\uFF01-\uFF5E]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0)) // 全角→半角
    .replace(/[\u3000\s\u200B-\u200D\uFEFF]/g, '')                                      // 去空白与零宽
    .replace(/[.\u3002,，、\-_~＊*·•+]/g, '')                                            // 去分隔符
    .toLowerCase()
}
// 只去空白/零宽，保留标点，用于网址/域名检测
function plain(s) {
  return (s ?? '').toString()
    .replace(/[\uFF01-\uFF5E]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0))
    .replace(/[\u3000\s\u200B-\u200D\uFEFF]/g, '')
    .toLowerCase()
}

// 广告 / 引流关键词（在 tight 串上匹配）
const AD_WORDS = [
  // 联系方式与社交账号
  '微信', 'weixin', 'wechat', 'vx', 'v信', '加v', '扣扣', 'qq', 'q群', 'qq群',
  '企鹅', '加我', '联系我', '私聊', '私我', '私信我', '加好友', '扫一扫', '扫码',
  '二维码', '公众号', '视频号', '抖音', '快手', '小红书', '淘宝', '拼多多',
  '淘宝店', '闲鱼', '微博', 'b站', 'telegram', 'tme',
  // 广告营销
  '兼职', '刷单', '日赚', '月入', '躺赚', '代购', '返利', '返现', '领券', '优惠券',
  '免费领', '免费送', '免费看', '点击领取', '抢购', '秒杀', '特价', '批发', '招商',
  '加盟', '代理', '招募', '推广', '引流', '涨粉', '加粉', '一手货源', '厂家直销',
  // 灰产 / 违规
  '博彩', '赌博', '彩票', '贷款', '套现', '刷卡', '发票', '代开', '外挂', '辅助',
  '脚本', '破解', '爆破', '跑分', '刷钻', '刷粉', '代刷', '代充', '低价充值',
]

// 真实网址 / 域名（在 plain 串上匹配）
const URL_RE = /(https?:\/\/|www\.|[a-z0-9-]+\.(com|cn|net|org|top|xyz|cc|me|io|info|vip|club)(\/|$|\?)|t\.me\/)/

// 手机号：1[3-9] 开头 11 位
const PHONE_RE = /1[3-9]\d{9}/

// QQ号：5~11 位连续数字，排除明显年份(19xx/20xx)
// - nickname/username：5 位起即拦（正常名号不会有一长串数字）
// - comment：6 位起拦（评论里 5 位数字更可能是随手输入，放宽以减少误伤）
function hitQQ(t, minLen) {
  const re = new RegExp(`[1-9]\\d{${minLen - 1},10}`, 'g')
  let m
  while ((m = re.exec(t)) !== null) {
    const n = m[0]
    // 年份 19xx / 20xx 开头且总长 4：不会被本正则匹配（minLen>=5）
    // 数字后紧跟「年/月/日/集/元/块/个/楼/楼」等量词视为正常表达
    const after = t[m.index + n.length] || ''
    if (after && '年月日集元块钱个楼层'.includes(after)) continue
    return n
  }
  return null
}

function check(raw, kind) {
  const t = tight(raw)
  if (!t) return { blocked: false }

  // 广告关键词
  for (const w of AD_WORDS) {
    if (t.includes(w)) return { blocked: true, reason: `含广告或引流内容「${w}」` }
  }
  // 网址链接
  if (URL_RE.test(plain(raw))) return { blocked: true, reason: '含网址链接' }
  // 手机号
  if (PHONE_RE.test(t)) return { blocked: true, reason: '含手机号码' }
  // QQ号（名号/用户名 5 位起，评论 6 位起）
  const qq = hitQQ(t, kind === 'comment' ? 6 : 5)
  if (qq) return { blocked: true, reason: `含疑似QQ号「${qq.slice(0, 3)}****${qq.slice(-2)}」` }

  return { blocked: false }
}

// 名号（昵称）：较严格
export function checkNickname(raw) {
  const r = check(raw, 'nickname')
  return r.blocked ? { blocked: true, reason: `名号${r.reason}，请修改` } : r
}
// 用户名：只拦明显的广告/联系方式，纯数字用户名常见，QQ号放宽到 6 位起
export function checkUsername(raw) {
  const t = tight(raw)
  if (!t) return { blocked: false }
  // 用户名本身受字符集限制，只查广告词、网址、手机号、长QQ号
  for (const w of AD_WORDS) {
    if (t.includes(w)) return { blocked: true, reason: `用户名${w}相关内容，请更换` }
  }
  if (PHONE_RE.test(t)) return { blocked: true, reason: '用户名含手机号码，请更换' }
  const qq = hitQQ(t, 6)
  if (qq) return { blocked: true, reason: '用户名含疑似QQ号，请更换' }
  return { blocked: false }
}
// 评论：相对宽松，6 位起拦 QQ 号
export function checkComment(raw) {
  const r = check(raw, 'comment')
  return r.blocked ? { blocked: true, reason: `评论${r.reason}，请勿发布` } : r
}
