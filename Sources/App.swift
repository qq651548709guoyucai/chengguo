import SwiftUI

@main
struct ChengGuoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 数据层（调自建 REST 代理）
@MainActor
final class DramaStore: ObservableObject {
    // 底部 Tab 选中项：0 首页 / 1 播放 / 2 搜索 / 3 我的
    @Published var selectedTab = 0
    // 当前正在播放的剧（各入口点剧集后设置，播放页读取）
    @Published var playingDrama: SeriesItem?

    /// 从任意入口打开一部剧：设置播放对象并切到播放 Tab
    func openPlayer(_ drama: SeriesItem) {
        playingDrama = drama
        selectedTab = 1
    }

    // 首页推荐
    @Published var feedItems: [SeriesItem] = []
    @Published var feedError: String?
    @Published var feedLoading = false
    @Published var feedType = "real"   // real 真人剧 / comic 漫剧 / ai AI剧

    // 搜索页
    @Published var searchItems: [SeriesItem] = []
    @Published var searchText = ""
    @Published var searchError: String?
    @Published var hasSearched = false
    // 搜索数据源：all=红果+苹果CMS / hg=红果 / cms=苹果CMS（记住选择）
    @Published var searchSource: String = {
        let s = UserDefaults.standard.string(forKey: "searchSource") ?? "all"
        return ["all", "hg", "cms"].contains(s) ? s : "all"
    }() {
        didSet { UserDefaults.standard.set(searchSource, forKey: "searchSource") }
    }

    // 热搜
    @Published var hotWords: [String] = []
    @Published var hotDramas: [HotDrama] = []
    @Published var hotLoading = false

    /// 推荐流（按当前类型）
    func loadFeed() async {
        feedLoading = true
        feedError = nil
        defer { feedLoading = false }
        do {
            feedItems = try await Api.feed(type: feedType).items
        } catch {
            feedError = "推荐加载失败：\(error.localizedDescription)"
        }
    }

    /// 切换类型：先清空旧数据，避免切过去还看到上一类
    func switchFeedType(_ type: String) async {
        guard type != feedType else { return }
        feedType = type
        feedItems = []
        feedLoading = true
        feedError = nil
        defer { feedLoading = false }
        do {
            feedItems = try await Api.feed(type: type).items
        } catch {
            feedError = "推荐加载失败：\(error.localizedDescription)"
        }
    }

    /// 下拉刷新：服务端每次返回打乱后的不同剧集
    func reloadFeed() async {
        feedError = nil
        do {
            feedItems = try await Api.feed(type: feedType).items
        } catch {
            feedError = "推荐加载失败，下拉重试"
        }
    }

    /// 搜索
    func search(_ q: String) async {
        let kw = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        hasSearched = true
        searchError = nil
        do {
            searchItems = try await Api.search(kw, source: searchSource).items
            if searchItems.isEmpty { searchError = "没有搜到「\(kw)」，换个关键词试试" }
        } catch {
            searchError = "搜索失败：\(error.localizedDescription)"
        }
    }

    /// 热搜（图文，每次进入强制刷新）
    func loadHot(force: Bool = false) async {
        if hotLoading { return }
        if !force && !hotDramas.isEmpty { return }
        hotLoading = true
        defer { hotLoading = false }
        do {
            let items = try await Api.hotDramas()
            hotDramas = items
            hotWords = items.map { $0.title }
        } catch {
            print("hot error:", error)
        }
    }

    static let shared = DramaStore()
}

// MARK: - 根视图：登录门 + 底部 Tab（首页 / 播放 / 搜索 / 我的）
struct ContentView: View {
    @StateObject private var store = DramaStore.shared
    @ObservedObject private var library = LibraryStore.shared
    @State private var popupAnnouncements: [Api.Announcement] = []
    @State private var showAnnouncementPopup = false

    var body: some View {
        Group {
            if library.didEnterApp {
                mainTabs
            } else {
                LoginView()
            }
        }
        .task {
            await library.restoreSession()   // 有 token 则校验并拉取云端数据
            await checkAnnouncements()       // 有新公告则弹出
        }
        .fullScreenCover(isPresented: $showAnnouncementPopup) {
            AnnouncementPopupView(announcements: popupAnnouncements) {
                // 记录已读，避免下次重复弹
                var seen = Set(UserDefaults.standard.stringArray(forKey: "cg_seen_announcements") ?? [])
                popupAnnouncements.forEach { seen.insert($0.id) }
                UserDefaults.standard.set(Array(seen), forKey: "cg_seen_announcements")
                showAnnouncementPopup = false
            }
        }
    }

    /// 拉取公告；只要有未读公告就弹窗（多条一起）
    private func checkAnnouncements() async {
        do {
            let all = try await Api.announcements()
            let seen = Set(UserDefaults.standard.stringArray(forKey: "cg_seen_announcements") ?? [])
            let unread = all.filter { !seen.contains($0.id) }
            if !unread.isEmpty {
                popupAnnouncements = unread
                showAnnouncementPopup = true
            }
        } catch {
            // 公告拉取失败不影响主流程
        }
    }

    private var mainTabs: some View {
        TabView(selection: $store.selectedTab) {
            NavigationView {
                HomeView(store: store)
            }
            .navigationViewStyle(.stack)
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }
            .tag(0)

            // 独立播放页（不带 NavigationView，全屏沉浸）
            PlayView(store: store)
                .tabItem {
                    Label("播放", systemImage: "play.rectangle.fill")
                }
                .tag(1)

            NavigationView {
                SearchView(store: store)
            }
            .navigationViewStyle(.stack)
            .tabItem {
                Label("搜索", systemImage: "magnifyingglass")
            }
            .tag(2)

            // 影视（电影/电视剧/综艺/动漫）
            VodView()
                .tabItem {
                    Label("影视", systemImage: "tv.fill")
                }
                .tag(3)

            NavigationView {
                LibraryView()
            }
            .navigationViewStyle(.stack)
            .tabItem {
                Label("我的", systemImage: "heart.fill")
            }
            .tag(4)
        }
        .accentColor(.orange)
    }
}
