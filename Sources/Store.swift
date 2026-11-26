import Foundation
import SwiftUI

// MARK: - 本地 + 云端：收藏 / 点赞 / 观看进度 / 账号

/// 某一部剧的观看进度
struct WatchProgress: Codable {
    let seriesId: String
    let series: SeriesItem      // 存整部剧，便于"继续观看"列表直接展示
    let episodeIndex: Int       // 看到第几集（0 基）
    let episodeTitle: String
    let seconds: Double         // 该集播放到的秒数
    let duration: Double        // 该集总时长
    let updatedAt: Date

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    var displayText: String {
        "第\(episodeIndex + 1)集 · \(Self.fmt(seconds)) / \(Self.fmt(duration))"
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var favorites: [SeriesItem] = []
    @Published var likedIds: Set<String> = []
    @Published var progress: [String: WatchProgress] = [:]

    // ---------- 账号 ----------
    @Published var token: String {
        didSet { d.set(token, forKey: kToken) }
    }
    @Published var username: String {
        didSet { d.set(username, forKey: kUsername) }
    }
    @Published var currentUser: Api.AccountUser?
    @Published var isSyncing = false
    @Published var guestMode: Bool {
        didSet { d.set(guestMode, forKey: kGuest) }
    }
    var isLoggedIn: Bool { !token.isEmpty }
    /// 是否已进入主界面（登录过或选了游客）
    var didEnterApp: Bool { isLoggedIn || guestMode }

    private let d = UserDefaults.standard
    private let kFav = "cg_favorites_v1"
    private let kLike = "cg_liked_v1"
    private let kProgress = "cg_progress_v1"
    private let kToken = "cg_token_v1"
    private let kUsername = "cg_username_v1"
    private let kGuest = "cg_guest_v1"
    private let kSavedPassword = "cg_saved_password_v1"   // 旧版明文密码键（仅用于迁移后清除）
    private var uploadTask: Task<Void, Never>?
    private var sessionChecked = false

    // 登录页自动填充用
    @Published var savedUsername: String
    @Published var savedPassword: String
    @Published var rememberCredentials: Bool

    private init() {
        token = d.string(forKey: kToken) ?? ""
        username = d.string(forKey: kUsername) ?? ""
        guestMode = d.bool(forKey: kGuest)
        savedUsername = d.string(forKey: "cg_saved_username_v1") ?? ""
        // 修复 L4：密码改从钥匙串读取；并把历史明文密码迁移到钥匙串后清除 UserDefaults
        if let kcPwd = Keychain.load() {
            savedPassword = kcPwd
        } else if let legacy = d.string(forKey: kSavedPassword), !legacy.isEmpty {
            savedPassword = legacy
            Keychain.save(legacy)
            d.removeObject(forKey: kSavedPassword)
        } else {
            savedPassword = ""
        }
        rememberCredentials = (d.object(forKey: "cg_remember_v1") != nil)
            ? d.bool(forKey: "cg_remember_v1") : true   // 默认记住
        load()
    }

    /// 登录/注册成功后记住账号密码（下次登录页自动填）
    /// 修复 L4：密码写入系统钥匙串，不再明文落 UserDefaults
    func remember(username u: String, password p: String) {
        savedUsername = u
        savedPassword = p
        d.set(u, forKey: "cg_saved_username_v1")
        Keychain.save(p)
        d.removeObject(forKey: kSavedPassword)   // 清除可能残留的历史明文
    }

    func enterGuest() { guestMode = true }

    // MARK: 本地读取
    private func load() {
        if let data = d.data(forKey: kFav),
           let arr = try? JSONDecoder().decode([SeriesItem].self, from: data) { favorites = arr }
        if let data = d.data(forKey: kLike),
           let arr = try? JSONDecoder().decode([String].self, from: data) { likedIds = Set(arr) }
        if let data = d.data(forKey: kProgress),
           let map = try? JSONDecoder().decode([String: WatchProgress].self, from: data) { progress = map }
    }
    private func saveFav() { if let x = try? JSONEncoder().encode(favorites) { d.set(x, forKey: kFav) } }
    private func saveLike() { if let x = try? JSONEncoder().encode(Array(likedIds)) { d.set(x, forKey: kLike) } }
    private func saveProgress() { if let x = try? JSONEncoder().encode(progress) { d.set(x, forKey: kProgress) } }

    /// 本地改动后：先落本地，再节流上传云端
    private func persistAndSync() {
        saveFav(); saveLike(); saveProgress()
        scheduleCloudUpload()
    }

    private func scheduleCloudUpload() {
        guard isLoggedIn, !token.isEmpty else { return }
        uploadTask?.cancel()
        uploadTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // 1.5 秒节流
            guard !Task.isCancelled, self.isLoggedIn else { return }
            await self.uploadNow()
        }
    }

    func uploadNow() async {
        guard isLoggedIn, !token.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        var clean: [String: Any] = ["likedIds": Array(likedIds)]
        if let favData = try? JSONEncoder().encode(favorites),
           let favJson = try? JSONSerialization.jsonObject(with: favData) { clean["favorites"] = favJson }
        if let progData = try? JSONEncoder().encode(progress),
           let progJson = try? JSONSerialization.jsonObject(with: progData) { clean["progress"] = progJson }
        try? await Api.uploadData(clean, token: token)
    }

    // MARK: 登录 / 注册 / 登出
    func login(username: String, password: String) async throws {
        let r = try await Api.login(username: username, password: password)
        applyAuth(r)
        remember(username: username, password: password)
        await pullFromCloud()
    }

    func register(username: String, password: String) async throws {
        let r = try await Api.register(username: username, password: password)
        applyAuth(r)
        remember(username: username, password: password)
        // 新注册：把当前本地数据作为初始值上传
        await uploadNow()
    }

    private func applyAuth(_ r: Api.AuthResponse) {
        token = r.token
        username = r.user.username
        currentUser = r.user
        guestMode = false
    }

    func logout() {
        token = ""
        currentUser = nil
        guestMode = false   // 登出后回到登录页
        uploadTask?.cancel()
    }

    /// 修改密码（成功返回，失败抛错由界面展示）
    func changePassword(old: String, new: String) async throws {
        try await Api.changePassword(oldPassword: old, newPassword: new, token: token)
        // 修复 M6：同步更新本地记住的密码，否则之后评论 401 触发的
        // reLoginSilently() 会用旧密码登录，自愈链断裂。
        if rememberCredentials {
            remember(username: savedUsername.isEmpty ? username : savedUsername, password: new)
        }
    }

    /// token 失效时用保存的账号密码静默重新登录，成功返回 true。
    /// 用于发评论等场景遇到 401 时自愈，用户无感知。
    func reLoginSilently() async -> Bool {
        guard !savedUsername.isEmpty, !savedPassword.isEmpty else { return false }
        do {
            let r = try await Api.login(username: savedUsername, password: savedPassword)
            token = r.token
            username = r.user.username
            currentUser = r.user
            guestMode = false
            return true
        } catch {
            return false
        }
    }

    /// 启动时调用：有 token 就校验并拉云端数据。
    /// 核心原则：绝不因为网络/校验问题把人踢回登录页。
    /// 只有用户主动点「退出」才会回登录页。token 失效也静默处理，
    /// 保证「登录一次后一直保持登录」。
    func restoreSession() async {
        if sessionChecked { return }
        sessionChecked = true
        guard isLoggedIn else { return }
        await verifyAndSync()
    }

    /// 后台静默重试：网络恢复后补拉云端数据，不影响登录态。
    /// 修复 M4：改为有限次数 + 指数退避，断网时不再永久每 8 秒循环耗电耗流量。
    func retrySyncInBackground(attempt: Int = 0) async {
        let maxAttempts = 5
        guard isLoggedIn, attempt < maxAttempts else { return }
        let delay = min(8 * (1 << attempt), 120)   // 8/16/32/64/120 秒
        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        guard isLoggedIn else { return }
        await verifyAndSync(attempt: attempt + 1)
    }

    private func verifyAndSync(attempt: Int = 0) async {
        do {
            let user = try await Api.getMe(token: token)
            currentUser = user
            await pullFromCloud()
        } catch {
            // 修复 M5：token 真失效时先尝试静默重登，成功后重新校验同步。
            if let apiError = error as? ApiError, apiError.isUnauthorized,
               attempt < 3, await reLoginSilently() {
                // 必须递增 attempt：若新 token 仍被判 401，用相同值递归会无限重登
                await verifyAndSync(attempt: attempt + 1)
                return
            }
            // 网络错误 / 服务端故障：保留本地登录态，用户照常进主界面用本地数据。
            // 不再自动 logout —— 只有「退出」按钮能登出。
            // 修复 M4：后台重试带次数上限，不再无限循环。
            Task { await self.retrySyncInBackground(attempt: attempt) }
        }
    }

    func pullFromCloud() async {
        guard isLoggedIn else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let cloud = try await Api.fetchData(token: token)
            favorites = cloud.favorites
            likedIds = Set(cloud.likedIds)
            progress = cloud.progress
            saveFav(); saveLike(); saveProgress()
        } catch {
            print("pull cloud failed:", error)
        }
    }

    // MARK: 收藏
    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }
    func toggleFavorite(_ series: SeriesItem) {
        if let i = favorites.firstIndex(where: { $0.id == series.id }) { favorites.remove(at: i) }
        else { favorites.insert(series, at: 0) }
        persistAndSync()
    }
    func removeFavorite(_ id: String) {
        favorites.removeAll { $0.id == id }
        persistAndSync()
    }

    // MARK: 点赞
    func isLiked(_ id: String) -> Bool { likedIds.contains(id) }
    func toggleLike(_ id: String) {
        if likedIds.contains(id) { likedIds.remove(id) } else { likedIds.insert(id) }
        persistAndSync()
    }

    // MARK: 观看进度
    func saveWatch(_ p: WatchProgress) {
        progress[p.seriesId] = p
        persistAndSync()
    }
    func watch(for seriesId: String) -> WatchProgress? { progress[seriesId] }
    func removeWatch(_ seriesId: String) {
        progress.removeValue(forKey: seriesId)
        persistAndSync()
    }
    func clearAllWatch() {
        progress.removeAll()
        persistAndSync()
    }
    func sortedWatch() -> [WatchProgress] { progress.values.sorted { $0.updatedAt > $1.updatedAt } }
}
