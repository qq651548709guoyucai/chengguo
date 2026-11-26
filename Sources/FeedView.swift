import SwiftUI
import AVKit

// MARK: - 首页：九宫格

struct HomeView: View {
    @ObservedObject var store: DramaStore
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private let types: [(key: String, label: String)] = [
        ("real", "真人剧"), ("comic", "漫剧"), ("ai", "AI剧"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部分类切换
            HStack(spacing: 8) {
                ForEach(types, id: \.key) { t in
                    Button {
                        Task { await store.switchFeedType(t.key) }
                    } label: {
                        Text(t.label)
                            .font(.system(size: 14, weight: store.feedType == t.key ? .semibold : .regular))
                            .foregroundColor(store.feedType == t.key ? .black : .white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(store.feedType == t.key ? Color.orange : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Group {
                if store.feedLoading && store.feedItems.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().tint(.orange)
                        Text("正在加载推荐...").font(.footnote).foregroundColor(.white.opacity(0.6))
                    }
                } else if let err = store.feedError, store.feedItems.isEmpty {
                    PlaceholderCard(error: err) {
                        Task { await store.loadFeed() }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.feedItems) { drama in
                                Button {
                                    store.openPlayer(drama)
                                } label: {
                                    PosterCell(drama: drama)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                    .refreshable { await store.reloadFeed() }
                }
            }
        }
        .background(Color.black)
        .navigationTitle("熬夜看短剧")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if store.feedItems.isEmpty { await store.loadFeed() }
        }
    }
}

// MARK: - 九宫格封面卡片

struct PosterCell: View {
    let drama: SeriesItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: drama.coverUrl)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    ZStack {
                        Color(.systemGray5).opacity(0.25)
                        Image(systemName: "film").foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9.0 / 12.0, contentMode: .fill)
            .clipped()
            .cornerRadius(10)

            Text(drama.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(height: 34, alignment: .top)

            if drama.episodeCount > 0 {
                Text("全 \(drama.episodeCount) 集")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - 热搜剧封面卡片（排名 + 角标 + 热度）

struct HotDramaCell: View {
    let hot: HotDrama

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                AsyncImage(url: URL(string: hot.coverUrl)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        ZStack {
                            Color(.systemGray5).opacity(0.25)
                            Image(systemName: "film").foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(9.0 / 12.0, contentMode: .fill)
            }
            .clipped()
            .cornerRadius(10)
            .overlay(alignment: .topLeading) {
                Text("\(hot.rank)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(hot.rank <= 3 ? Color.orange : Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if !hot.tag.isEmpty {
                    Text(hot.tag)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .padding(6)
                }
            }

            Text(hot.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(height: 34, alignment: .top)

            if !hot.description.isEmpty {
                Text(hot.description)
                    .font(.caption2)
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 搜索页（独立 Tab）

struct SearchView: View {
    @ObservedObject var store: DramaStore
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    // 红果官方 API：搜索联想词
    @State private var suggestions: [Api.Suggestion] = []
    @State private var suggestTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部搜索框（在搜索页内，不在首页）
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.6))
                    TextField("搜索短剧名", text: $store.searchText)
                        .foregroundColor(.white)
                        .submitLabel(.search)
                        .onSubmit {
                            suggestions = []
                            Task { await store.search(store.searchText) }
                        }
                        // 红果联想词：300ms 防抖，避免每敲一个字就请求
                        .onChange(of: store.searchText) { newValue in
                            suggestTask?.cancel()
                            let q = newValue.trimmingCharacters(in: .whitespaces)
                            guard !q.isEmpty else { suggestions = []; return }
                            suggestTask = Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                guard !Task.isCancelled else { return }
                                if let items = try? await Api.suggest(q), !Task.isCancelled {
                                    suggestions = Array(items.prefix(8))
                                }
                            }
                        }
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                            store.hasSearched = false
                            suggestions = []
                            suggestTask?.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.white.opacity(0.15), in: Capsule())

                Button("搜索") { Task { await store.search(store.searchText) } }
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // 红果联想词下拉（有输入且未提交搜索时显示）
            if !suggestions.isEmpty && !store.hasSearched {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { s in
                            Button {
                                store.searchText = s.keyword
                                suggestions = []
                                Task { await store.search(s.keyword) }
                            } label: {
                                Text(s.text)
                                    .font(.footnote)
                                    .foregroundColor(.white.opacity(0.9))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 6)
            }

            if !store.hasSearched {
                hotSearchView
            } else if let err = store.searchError, store.searchItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.4))
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.searchItems) { drama in
                            Button {
                                store.openPlayer(drama)
                            } label: {
                                PosterCell(drama: drama)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color.black)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 每次进入搜索页强制刷新热搜
            await store.loadHot(force: true)
        }
    }

    private var hotSearchView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("热搜榜", systemImage: "flame.fill")
                        .foregroundColor(.orange)
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await store.loadHot(force: true) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                if store.hotLoading && store.hotDramas.isEmpty {
                    HStack { Spacer(); ProgressView().tint(.orange); Spacer() }
                        .padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.hotDramas) { hot in
                            Button {
                                store.openPlayer(hot.asSeries)
                            } label: {
                                HotDramaCell(hot: hot)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
        .refreshable { await store.loadHot(force: true) }
    }
}

// MARK: - 播放详情页

struct DetailView: View {
    let drama: SeriesItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            FeedCard(drama: drama, autoPlay: true)

            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 6)
            .padding(.leading, 12)
        }
        .navigationBarHidden(true)
    }
}

struct PlaceholderCard: View {
    var error: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if let error {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundColor(.yellow)
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                if let retry {
                    Button("重试") { retry() }
                        .font(.subheadline.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.orange, in: Capsule())
                        .foregroundColor(.white)
                }
            } else {
                ProgressView().tint(.white)
                Text("加载中...")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - 单剧播放器（全屏播放 + 信息 + 选集）

struct FeedCard: View {
    let drama: SeriesItem
    var autoPlay: Bool = false
    @StateObject private var model: CardModel
    @ObservedObject private var library = LibraryStore.shared
    @State private var showComments = false

    init(drama: SeriesItem, autoPlay: Bool = false) {
        self.drama = drama
        self.autoPlay = autoPlay
        _model = StateObject(wrappedValue: CardModel(drama: drama))
    }

    var body: some View {
        ZStack {
            if model.player != nil {
                TencentPlayerView(model: model)
                    .ignoresSafeArea()
            } else {
                // 封面
                AsyncImage(url: URL(string: drama.coverUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.black
                }
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.25))

                // 错误提示 + 重试
                if let msg = model.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.yellow)
                        Text(msg)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Button("重试") {
                            Task { await model.start() }
                        }
                        .font(.subheadline.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.orange, in: Capsule())
                        .foregroundColor(.white)
                    }
                    .foregroundColor(.white)
                } else {
                    // 播放按钮
                    Button {
                        Task { await model.start() }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 64))
                            Text(model.loading ? "加载中..." : "播放《\(drama.title)》")
                                .font(.subheadline)
                        }
                        .foregroundColor(.white)
                        .shadow(radius: 4)
                    }
                    .disabled(model.loading)
                }
            }

            // 底部信息
            VStack {
                Spacer()
                // 断点续播提示（4 秒后淡出）
                if let tip = model.resumeTip {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(tip)
                            .font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !drama.description.isEmpty {
                            Text(drama.description)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(2)
                        }
                        if drama.episodeCount > 0 {
                            Text("全 \(drama.episodeCount) 集")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    Button { showComments = true } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 23))
                            Text("评论").font(.caption2)
                        }
                        .foregroundColor(.white)
                    }
                    Button {
                        library.toggleLike(drama.id)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: library.isLiked(drama.id) ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 23))
                            Text("赞").font(.caption2)
                        }
                        .foregroundColor(library.isLiked(drama.id) ? .orange : .white)
                    }
                    Button {
                        library.toggleFavorite(drama)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: library.isFavorite(drama.id) ? "heart.fill" : "heart")
                                .font(.system(size: 23))
                            Text("收藏").font(.caption2)
                        }
                        .foregroundColor(library.isFavorite(drama.id) ? .pink : .white)
                    }
                    Button {
                        model.showQuality = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 24))
                            Text(model.quality).font(.caption2)
                        }
                        .foregroundColor(.orange)
                    }
                    Button {
                        model.showEpisodes = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 24))
                            Text("选集").font(.caption2)
                        }
                        .foregroundColor(.white)
                    }
                }
                .padding(14)
            }

            // 顶部集数信息条（第几集 / 共几集）
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(drama.title)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("第 \(model.currentIndex + 1) 集")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                            if model.episodes.count > 0 {
                                Text("/ 共 \(model.episodes.count) 集")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.65))
                            } else if drama.episodeCount > 0 {
                                Text("/ 共 \(drama.episodeCount) 集")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.65))
                            }
                        }
                        if !model.currentTitle.isEmpty {
                            Text(model.currentTitle)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                Spacer()
            }
            .allowsHitTesting(false)

            // 切集边界提示（居中）
            if let tip = model.switchTip {
                VStack {
                    Spacer()
                    Text(tip)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.7), in: Capsule())
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .alert("解锁全部剧集", isPresented: $model.showLoginHint) {
            Button("去登录") {
                // 退出游客模式，回到登录页
                library.guestMode = false
                library.token = ""
                DramaStore.shared.selectedTab = 0
            }
            Button("稍后再说", role: .cancel) {}
        } message: {
            Text("游客可免费试看前2集，登录后解锁全部剧集并同步收藏与进度。")
        }
        .onDisappear { model.pause() }
        .onAppear { model.resume() }
        .task {
            if autoPlay && model.player == nil { await model.start() }
        }
        .sheet(isPresented: $model.showEpisodes) {
            EpisodeSheet(model: model)
        }
        .sheet(isPresented: $showComments) {
            CommentsView(seriesId: drama.id, seriesTitle: drama.title)
        }
        .confirmationDialog("选择画质", isPresented: $model.showQuality, titleVisibility: .visible) {
            ForEach(["1080p", "720p", "480p"], id: \.self) { q in
                Button {
                    Task { await model.setQuality(q) }
                } label: {
                    Text(q + (q == "1080p" ? "（高清·推荐）" : (q == "480p" ? "（省流量）" : "")))
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前：\(model.quality)。高清画质更清晰但流量消耗更大。")
        }
    }
}

// MARK: - 卡片播放模型

@MainActor
final class CardModel: ObservableObject {
    let drama: SeriesItem
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var showEpisodes = false
    @Published var episodes: [EpisodeItem] = []
    @Published var epCursor = ""
    @Published var epHasMore = false
    @Published var epLoading = false   // 修复 H3：分集加载锁，防止并发重复请求
    @Published var currentIndex = 0
    @Published var currentTitle = ""
    @Published var statusText: String?
    @Published var errorMessage: String?
    @Published var showQuality = false
    @Published var resumeTip: String?     // 断点续播提示，几秒后自动消失
    @Published var switchTip: String?     // 切集边界提示（第一集/最后一集）
    @Published var showLoginHint = false  // 游客点受限集时弹登录引导
    @Published var quality: String = {
        let saved = UserDefaults.standard.string(forKey: "cg_quality") ?? ""
        return ["1080p", "720p", "480p"].contains(saved) ? saved : "1080p"
    }()

    // MARK: 腾讯视频式播放器状态
    @Published var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var totalSeconds: Double = 0
    @Published var speed: Float = UserDefaults.standard.float(forKey: "cg_speed") == 0
        ? 1.0 : UserDefaults.standard.float(forKey: "cg_speed")
    @Published var fullScreen = false
    @Published var showControls = true
    private var hideControlsTask: Task<Void, Never>?

    /// 游客免费试看前2集；登录用户解锁全部
    private var isGuest: Bool { !LibraryStore.shared.isLoggedIn }
    private let freeEpisodeLimit = 2
    /// 该集是否允许播放
    private func canPlay(index: Int) -> Bool { !isGuest || index < freeEpisodeLimit }
    /// 选集页展示锁标用：游客且第3集起为锁定
    func isEpisodeLocked(_ index: Int) -> Bool { !canPlay(index: index) }

    private var started = false
    private var endObserver: NSObjectProtocol?
    private var playerErrorObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var lastSeconds: Double = 0
    private var lastDuration: Double = 0
    private var preloadedEpisodeId: String?   // 已预热的下一集，避免重复请求

    init(drama: SeriesItem) {
        self.drama = drama
    }

    deinit {
        // 修复 L3：deinit 是非隔离上下文，不能碰 @MainActor 隔离的 player。
        // 只移除通知观察者（NSObjectProtocol 非隔离，安全）；
        // player/timeObserver 的清理放到 pause()（MainActor）里，由 onDisappear 调用。
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = playerErrorObserver { NotificationCenter.default.removeObserver(o) }
    }

    func start() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        if episodes.isEmpty { await loadEpisodes() }
        guard !episodes.isEmpty else {
            errorMessage = "分集加载失败，点击重试"
            return
        }

        // 断点续播：读取上次看到第几集、第几秒（只在同一部剧内）
        var targetIndex = 0
        var seekTo: Double? = nil
        if let saved = LibraryStore.shared.watch(for: drama.id),
           episodes.indices.contains(saved.episodeIndex) {
            // 游客只能续播前2集，避免落到受限集导致黑屏
            targetIndex = isGuest ? min(saved.episodeIndex, freeEpisodeLimit - 1) : saved.episodeIndex
            // 剩不到 5 秒或刚开始几秒就不跳，避免卡在片头/片尾
            if saved.seconds > 5 && saved.duration - saved.seconds > 5 {
                seekTo = saved.seconds
            }
            resumeTip = "上次看到 \(saved.displayText)，已为你续播"
        }
        await play(at: targetIndex, seekTo: seekTo)
        started = true

        // 提示 4 秒后自动淡出
        if resumeTip != nil {
            let tip = resumeTip
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.resumeTip == tip { self.resumeTip = nil }
            }
        }
    }

    func resume() {
        if started {
            player?.play()
            player?.rate = speed
            isPlaying = true
        }
    }
    func pause() {
        // 修复 L3：在 MainActor 上下文内清理 timeObserver 与 player，
        // 避免 deinit 里访问 @MainActor 属性触发 Swift 5.9 严格并发编译错误。
        isPlaying = false
        hideControlsTask?.cancel()
        if let t = timeObserver { player?.removeTimeObserver(t) }
        timeObserver = nil
        player?.pause()
        saveProgressIfNeeded()   // 退出页面时落盘当前进度
    }

    // MARK: - 腾讯视频式播放控制

    /// 播放/暂停切换
    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            showControls = true          // 暂停时常驻控件
        } else {
            player.play()
            isPlaying = true
            flashControls()
        }
    }

    /// 跳转（拖动进度条）
    func seek(to seconds: Double) {
        guard let player, totalSeconds > 0 else { return }
        let t = CMTime(seconds: max(0, min(seconds, totalSeconds)), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentSeconds = t.seconds
    }

    /// 快进/快退 delta 秒（正=前进，负=后退）
    func skip(_ delta: Double) {
        seek(to: currentSeconds + delta)
    }

    /// 倍速
    func setSpeed(_ s: Float) {
        speed = s
        UserDefaults.standard.set(s, forKey: "cg_speed")
        player?.rate = s
        if player?.timeControlStatus == .playing { isPlaying = true }
    }

    /// 全屏切换
    func toggleFullScreen() {
        fullScreen.toggle()
        VodOrientation.lock(fullScreen ? .landscapeRight : .portrait)
    }

    /// 闪一下控件，播放中 5 秒后自动隐藏
    func flashControls() {
        showControls = true
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.player?.timeControlStatus == .playing {
                self.showControls = false
            }
        }
    }

    /// 边界提示 1.5 秒后自动消失
    func scheduleTipClear() {
        let tip = switchTip
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.switchTip == tip { self.switchTip = nil }
        }
    }

    /// 后台预热下一集：提前取址 + 触发服务端解密缓存，切集时秒开
    func preloadNext() {
        let next = currentIndex + 1
        guard episodes.indices.contains(next) else { return }
        guard canPlay(index: next) else { return }   // 受限集不预热，避免无效请求
        let ep = episodes[next]
        guard ep.id != preloadedEpisodeId else { return }
        preloadedEpisodeId = ep.id
        let q = quality
        Task {
            // 预取播放地址；加密流再发一个小 Range 请求让服务端提前解密落缓存
            guard let result = try? await Api.play(ep.id) else { return }
            if result.protected == true {
                var req = URLRequest(url: Api.streamURL(ep.id, quality: q))
                req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    /// 把当前播放位置写入本地（切集/退出/播完时调用）
    func saveProgressIfNeeded() {
        guard started, episodes.indices.contains(currentIndex), lastSeconds > 0 else { return }
        let ep = episodes[currentIndex]
        let p = WatchProgress(
            seriesId: drama.id,
            series: drama,
            episodeIndex: currentIndex,
            episodeTitle: ep.title,
            seconds: lastSeconds,
            duration: lastDuration,
            updatedAt: Date()
        )
        LibraryStore.shared.saveWatch(p)
    }

    /// 下一集（滑动手势调用）：到底且还有更多则先加载
    func nextEpisode() async {
        var next = currentIndex + 1
        if !episodes.indices.contains(next) && epHasMore {
            await loadEpisodes()
        }
        guard episodes.indices.contains(next) else {
            switchTip = "已经是最后一集了"
            scheduleTipClear()
            return
        }
        await play(at: next)
    }

    /// 上一集（滑动手势调用）
    func prevEpisode() async {
        let prev = currentIndex - 1
        guard episodes.indices.contains(prev) else {
            switchTip = "已经是第一集了"
            scheduleTipClear()
            return
        }
        await play(at: prev)
    }

    /// 切换画质：记住选择并从当前集重新加载
    func setQuality(_ q: String) async {
        showQuality = false
        guard q != quality else { return }
        quality = q
        UserDefaults.standard.set(q, forKey: "cg_quality")
        if started, episodes.indices.contains(currentIndex) {
            await play(at: currentIndex)
        }
    }

    /// 加载分集（游标翻页）
    /// 修复 H3：加锁防止 start() 与选集页并发触发同一 cursor 重复追加；
    /// 并按 ep.id 去重，避免集数重复导致 currentIndex 错位。
    func loadEpisodes() async {
        guard !epLoading else { return }
        epLoading = true
        defer { epLoading = false }
        do {
            let cursor = epCursor.isEmpty ? nil : epCursor
            let page = try await Api.episodes(drama.id, cursor: cursor)
            var seen = Set(episodes.map { $0.id })
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            episodes += fresh
            epCursor = page.cursor ?? ""
            epHasMore = page.hasMore ?? false
        } catch {
            print("loadEpisodes error:", error)
        }
    }

    /// 解析播放地址：加密分集走服务端解密流，明流直接播
    /// seekTo: 断点续播要跳转到的秒数（仅首次进入该集时传）
    func play(at index: Int, seekTo: Double? = nil) async {
        guard episodes.indices.contains(index) else { return }
        // 游客免费试看前2集：第3集起拦截，弹登录引导（当前集继续播，不打断）
        guard canPlay(index: index) else {
            showLoginHint = true
            return
        }
        // 切集前先落盘上一集的进度（此时 currentIndex 还是旧集）
        saveProgressIfNeeded()
        // 切集（选集/下一集/切画质）时立即停掉当前音频，
        // 避免等待新播放地址的空档里旧集继续出声，造成两路音频重叠
        player?.pause()
        // 切到新集，进度归零，等待新 item 的观察者重新填充
        lastSeconds = 0
        lastDuration = 0
        currentSeconds = 0
        totalSeconds = 0
        isPlaying = false
        let ep = episodes[index]
        currentTitle = ep.title
        currentIndex = index
        errorMessage = nil
        do {
            // 取址偶发 502，自动重试 2 次（服务端已在换设备，这里兜瞬时失败）
            var result: PlayResult?
            for attempt in 0..<3 {
                do {
                    result = try await Api.play(ep.id)
                    break
                } catch {
                    if attempt == 2 { throw error }
                    try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s
                }
            }
            guard let result else {
                errorMessage = "播放源繁忙，请点重试"
                return
            }

            if result.protected == true {
                // 服务端已解密的 mp4 流（支持 Range），客户端零下载零解密
                startPlayer(url: Api.streamURL(ep.id, quality: quality), seekTo: seekTo)
            } else {
                // 明流：优先 540p/480p
                let streams = result.streams
                let stream = streams.first(where: { $0.definition == "540p" })
                    ?? streams.first(where: { $0.definition == "480p" })
                    ?? streams.last
                guard let url = stream?.url, let u = URL(string: url) else {
                    errorMessage = "没有可用的播放地址"
                    return
                }
                startPlayer(url: u, seekTo: seekTo)
            }

            // 播放器自身出错也展示出来
            if let o = playerErrorObserver { NotificationCenter.default.removeObserver(o) }
            playerErrorObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: player?.currentItem, queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                    self?.player = nil
                    self?.errorMessage = "播放出错：\(err?.localizedDescription ?? "未知错误")"
                }
            }

            // 播完自动下一集
            if let o = endObserver { NotificationCenter.default.removeObserver(o) }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player?.currentItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.episodes.indices.contains(self.currentIndex + 1) else { return }
                    await self.play(at: self.currentIndex + 1)
                }
            }

            // 当前集播起来后，后台预热下一集的取址与解密缓存，切集时秒开
            preloadNext()
        } catch {
            player = nil
            statusText = nil
            let msg = error.localizedDescription
            if msg.contains("502") || msg.contains("500") {
                errorMessage = "播放源开小差了，点重试再试一次"
            } else if msg.contains("-1009") || msg.contains("200") {
                errorMessage = "网络连接失败，检查网络后重试"
            } else {
                errorMessage = "加载失败，点重试再试一次"
            }
        }
    }

    private func startPlayer(url: URL, seekTo: Double? = nil) {
        // 关键：切换前先彻底停掉并释放旧播放器，否则旧实例的音频会在后台继续播
        if let old = player {
            if let o = timeObserver { old.removeTimeObserver(o); timeObserver = nil }
            old.pause()
            old.rate = 0
            old.replaceCurrentItem(with: nil)
        }
        // 清掉绑在旧 item 上的通知，避免旧的"播放结束"串台误触发下一集
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = playerErrorObserver { NotificationCenter.default.removeObserver(o); playerErrorObserver = nil }

        let newPlayer = AVPlayer(url: url)
        player = newPlayer

        // 每 1 秒记录播放位置与时长，用于断点续播
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.lastSeconds = time.seconds
                self.currentSeconds = time.seconds
                if let dur = newPlayer.currentItem?.duration, dur.isValid, dur.seconds.isFinite {
                    self.lastDuration = dur.seconds
                    self.totalSeconds = dur.seconds
                }
                // 播放中同步真实状态（系统可能自行暂停/恢复，如来电、切后台）
                self.isPlaying = newPlayer.timeControlStatus == .playing
            }
        }

        // 断点续播：item 可播后跳转到上次位置
        if let seekTo, seekTo > 0 {
            let t = CMTime(seconds: seekTo, preferredTimescale: 600)
            newPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            self.currentSeconds = seekTo
        }
        newPlayer.play()
        newPlayer.rate = speed
        isPlaying = true
        showControls = true
        flashControls()
    }
}
