import Foundation

// MARK: - 自建红果 REST 代理客户端（不再依赖 openhongguo SDK 与外挂签名）

enum ApiError: LocalizedError {
    case badStatus(Int)
    case server(String)      // 服务端返回的 error 文案
    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "接口请求失败 (\(c))"
        case .server(let m): return m
        }
    }
    /// 是否为登录失效（401）
    var isUnauthorized: Bool {
        if case .badStatus(let c) = self, c == 401 { return true }
        if case .server(let m) = self, m.contains("登录") || m.contains("未登录") { return true }
        return false
    }
}

struct SeriesItem: Identifiable, Codable {
    let id: String
    let title: String
    let coverUrl: String
    let description: String
    let episodeCount: Int
}

struct SeriesPage: Decodable {
    let items: [SeriesItem]
    let cursor: String?
    let hasMore: Bool?
}

struct EpisodeItem: Identifiable, Decodable {
    let id: String
    let title: String
}

struct EpisodePage: Decodable {
    let items: [EpisodeItem]
    let cursor: String?
    let hasMore: Bool?
}

struct PlayStream: Decodable {
    let codec: String?
    let definition: String?
    let url: String
}

// 热搜剧（带封面、排名、角标）
struct HotDrama: Identifiable, Decodable {
    let id: String
    let title: String
    let coverUrl: String
    let description: String
    let episodeCount: Int
    let rank: Int
    let tag: String
    let board: String
}

// 与 SeriesItem 互转，便于复用播放详情页
extension HotDrama {
    var asSeries: SeriesItem {
        SeriesItem(id: id, title: title, coverUrl: coverUrl, description: description, episodeCount: episodeCount)
    }
}

// 云端同步的数据包（与本地 LibraryStore 对应）
struct CloudData: Decodable {
    let favorites: [SeriesItem]
    let likedIds: [String]
    let progress: [String: WatchProgress]
}

struct ContentKeyInfo: Decodable { let key: String }

struct PlayResult: Decodable {
    let protected: Bool?
    let streams: [PlayStream]
    let contentKey: ContentKeyInfo?
}

enum Api {
    // 2026-11-24：切换到自建阿里云服务器（Nginx 反代 80 -> 3002）
    static let base = "http://47.100.207.19"
    static let sharecode = "5EIGEKAGSI"  // 服务端当前不校验，携带无害

    static func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        func buildRequest() -> URLRequest {
            var comps = URLComponents(string: base + path)!
            var qItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            qItems.append(URLQueryItem(name: "sharecode", value: sharecode))
            comps.queryItems = qItems
            var req = URLRequest(url: comps.url!, timeoutInterval: 30)
            req.addValue("application/json", forHTTPHeaderField: "Accept")
            // 已登录则带上 token，服务端据此放行第3集+（游客无 token 会被拦）
            // 直接读 UserDefaults，避免 @MainActor 隔离问题
            let tk = UserDefaults.standard.string(forKey: "cg_token_v1") ?? ""
            if !tk.isEmpty { req.setValue(tk, forHTTPHeaderField: "X-Token") }
            return req
        }

        let (data, resp) = try await URLSession.shared.data(for: buildRequest())
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // 修复 H2 配套：服务端改为校验 token 真实有效性后，失效 token 会被 403 拦截。
        // 若本地确实带了 token，静默重登后用新 token 重试一次，避免误伤合法用户。
        let hadToken = !(UserDefaults.standard.string(forKey: "cg_token_v1") ?? "").isEmpty
        if status == 403 && hadToken {
            let relogged = await LibraryStore.shared.reLoginSilently()
            if relogged {
                let (data2, resp2) = try await URLSession.shared.data(for: buildRequest())
                guard let http2 = resp2 as? HTTPURLResponse, http2.statusCode == 200 else {
                    throw ApiError.badStatus((resp2 as? HTTPURLResponse)?.statusCode ?? -1)
                }
                return try JSONDecoder().decode(T.self, from: data2)
            }
        }
        guard status == 200 else { throw ApiError.badStatus(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // ---------- 账号系统 ----------
    struct AuthResponse: Decodable {
        let token: String
        let user: AccountUser
    }
    struct AccountUser: Decodable, Equatable {
        let id: String
        let username: String
        let role: String
        let disabled: Bool?
    }

    /// 通用 POST（JSON body），带 token
    static func post<T: Decodable>(_ path: String, body: [String: Any], token: String? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        // 无论成功失败都尝试解 error 文案
        if let obj = try? JSONDecoder().decode([String: String].self, from: data), let err = obj["error"] {
            throw ApiError.server(err)
        }
        guard http?.statusCode == 200 else { throw ApiError.badStatus(http?.statusCode ?? -1) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func register(username: String, password: String) async throws -> AuthResponse {
        try await post("/api/auth/register", body: ["username": username, "password": password])
    }

    static func login(username: String, password: String) async throws -> AuthResponse {
        try await post("/api/auth/login", body: ["username": username, "password": password])
    }

    /// 修改密码（需登录），返回 ok
    static func changePassword(oldPassword: String, newPassword: String, token: String) async throws {
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await post("/api/auth/change-password",
                                   body: ["oldPassword": oldPassword, "newPassword": newPassword],
                                   token: token)
    }

    /// 上传/下载用户数据（收藏/点赞/进度）
    struct Empty: Decodable {}
    static func uploadData(_ payload: [String: Any], token: String) async throws {
        let _: Empty = try await post("/api/data", body: ["data": payload], token: token)
    }
    static func fetchData(token: String) async throws -> CloudData {
        var req = URLRequest(url: URL(string: base + "/api/data")!, timeoutInterval: 30)
        req.setValue(token, forHTTPHeaderField: "X-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ApiError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1) }
        return try JSONDecoder().decode(CloudData.self, from: data)
    }

    struct MeResponse: Decodable { let user: AccountUser }
    static func getMe(token: String) async throws -> AccountUser {
        var req = URLRequest(url: URL(string: base + "/api/auth/me")!, timeoutInterval: 30)
        req.setValue(token, forHTTPHeaderField: "X-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ApiError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1) }
        return try JSONDecoder().decode(MeResponse.self, from: data).user
    }

    static func feed(type: String = "real") async throws -> SeriesPage {
        try await get("/api/feed", query: ["type": type])
    }

    static func search(_ q: String) async throws -> SeriesPage {
        try await get("/api/search", query: ["q": q])
    }

    static func hotWords() async throws -> [String] {
        struct Hot: Decodable { let words: [String] }
        return (try await get("/api/hot") as Hot).words
    }

    static func hotDramas() async throws -> [HotDrama] {
        struct Hot: Decodable { let items: [HotDrama] }
        return (try await get("/api/hot") as Hot).items
    }

    static func episodes(_ seriesId: String, cursor: String?) async throws -> EpisodePage {
        var q: [String: String] = [:]
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return try await get("/api/episodes/\(seriesId)", query: q)
    }

    static func play(_ episodeId: String) async throws -> PlayResult {
        try await get("/api/play/\(episodeId)")
    }

    // ---------- 评论系统 ----------
    struct Comment: Decodable, Identifiable {
        let id: String
        let seriesId: String
        let seriesTitle: String
        let userId: String
        let username: String
        let role: String
        let text: String
        let parentId: String?
        let replyTo: String?
        let createdAt: Double
    }

    /// 拉取某部剧的评论（需登录）
    static func comments(seriesId: String, token: String) async throws -> [Comment] {
        var comps = URLComponents(string: base + "/api/comments")!
        comps.queryItems = [URLQueryItem(name: "seriesId", value: seriesId)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.setValue(token, forHTTPHeaderField: "X-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ApiError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1) }
        struct R: Decodable { let comments: [Comment] }
        return try JSONDecoder().decode(R.self, from: data).comments
    }

    /// 发评论 / 回复（parentId 为空则主评论）
    static func postComment(seriesId: String, seriesTitle: String, text: String, parentId: String?, token: String) async throws {
        var body: [String: Any] = ["seriesId": seriesId, "seriesTitle": seriesTitle, "text": text]
        if let parentId, !parentId.isEmpty { body["parentId"] = parentId }
        struct OK: Decodable { let comment: Comment }
        let _: OK = try await post("/api/comments", body: body, token: token)
    }

    /// 删除评论（本人或管理员）
    static func deleteComment(id: String, token: String) async throws {
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await post("/api/comments/delete", body: ["id": id], token: token)
    }

    // ---------- 公告系统 ----------
    struct Announcement: Decodable, Identifiable {
        let id: String
        let title: String
        let content: String
        let pinned: Bool
        let createdAt: Double
        let updatedAt: Double?
    }

    /// 公开拉取公告（无需登录）
    static func announcements() async throws -> [Announcement] {
        struct R: Decodable { let announcements: [Announcement] }
        return (try await get("/api/announcements") as R).announcements
    }

    /// 加密分集：服务端已解密的 mp4 流（支持 Range，AVPlayer 直接播）
    /// quality: 1080p / 720p / 480p，服务端按此选档并解密
    static func streamURL(_ episodeId: String, quality: String = "1080p") -> URL {
        var comps = URLComponents(string: "\(base)/api/stream/\(episodeId)")!
        var q = [URLQueryItem(name: "q", value: quality),
                 URLQueryItem(name: "sharecode", value: sharecode)]
        // AVPlayer 无法自定义 header，用 query 带 token 让服务端放行第3集+
        let tk = UserDefaults.standard.string(forKey: "cg_token_v1") ?? ""
        if !tk.isEmpty { q.append(URLQueryItem(name: "token", value: tk)) }
        comps.queryItems = q
        return comps.url!
    }

    // ---------- 影视系统（电影/电视剧/综艺/动漫）----------
    struct VodItem: Decodable, Identifiable, Hashable {
        let id: String
        let source: String?
        let title: String
        let cover: String?
        let year: String?
        let area: String?
        let typeName: String?
        let remarks: String?
        let score: String?
        let actors: String?
        let director: String?
    }
    struct VodList: Decodable {
        let items: [VodItem]
        let page: Int?
        let pagecount: Int?
        let total: Int?
        let source: String?
    }
    struct VodCategory: Decodable, Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }
    struct VodEpisode: Decodable, Identifiable {
        let title: String
        let url: String
        let index: Int
        var id: Int { index }
    }
    struct VodDetail: Decodable {
        let id: String
        let source: String?
        let title: String
        let cover: String?
        let year: String?
        let area: String?
        let typeName: String?
        let remarks: String?
        let score: String?
        let actors: String?
        let director: String?
        let content: String?
        let playFrom: String?
        let episodes: [VodEpisode]
    }

    static func vodCategories() async throws -> [VodCategory] {
        struct R: Decodable { let categories: [VodCategory] }
        return (try await get("/api/vod/categories") as R).categories
    }

    /// 影视列表/搜索。cat: movie/tv/variety/anime/all；wd 非空时为搜索
    static func vodList(cat: String, page: Int, keyword: String = "") async throws -> VodList {
        var q: [String: String] = ["cat": cat, "pg": String(page)]
        if !keyword.isEmpty { q["wd"] = keyword }
        return try await get("/api/vod/list", query: q)
    }

    static func vodDetail(id: String, source: String) async throws -> VodDetail {
        try await get("/api/vod/detail", query: ["id": id, "source": source])
    }
}
