import SwiftUI
import AVKit

// MARK: - 影视 Tab 根视图（分类浏览 + 搜索）

struct VodView: View {
    @StateObject private var store = VodStore.shared
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var selectedDetail: Api.VodDetail?
    @State private var selectedEpisode = 0
    @State private var detailError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    /// 点剧集封面：拉详情并打开选集页。失败时给出可见提示，杜绝静默黑屏。
    private func openDetail(id: String, source: String) async {
        do {
            let d = try await Api.vodDetail(id: id, source: source)
            detailError = nil
            selectedEpisode = 0
            selectedDetail = d
        } catch {
            detailError = "详情加载失败：\(error.localizedDescription)"
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 分类切换 + 搜索按钮
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.categories) { c in
                                Button {
                                    Task { await store.switchCategory(c.key) }
                                } label: {
                                    Text(c.label)
                                        .font(.system(size: 14, weight: store.category == c.key ? .semibold : .regular))
                                        .foregroundColor(store.category == c.key ? .black : .white.opacity(0.7))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(store.category == c.key ? Color.orange : Color.white.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16)).foregroundColor(.white)
                            .padding(8).background(Color.white.opacity(0.12), in: Circle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // 线路切换：自动 / 各资源站
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("线路").font(.caption).foregroundColor(.white.opacity(0.5))
                        Button {
                            Task { await store.switchSource("") }
                        } label: {
                            Text("自动")
                                .font(.system(size: 12, weight: store.source.isEmpty ? .semibold : .regular))
                                .foregroundColor(store.source.isEmpty ? .black : .white.opacity(0.7))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(store.source.isEmpty ? Color.orange : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        ForEach(store.sources) { s in
                            Button {
                                Task { await store.switchSource(s.name) }
                            } label: {
                                Text(s.label)
                                    .font(.system(size: 12, weight: store.source == s.name ? .semibold : .regular))
                                    .foregroundColor(store.source == s.name ? .black : .white.opacity(0.7))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Capsule().fill(store.source == s.name ? Color.orange : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                // 详情加载失败提示（可见，不再静默黑屏）
                if let err = detailError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(err).font(.caption).foregroundColor(.white.opacity(0.85))
                        Spacer()
                        Button { detailError = nil } label: {
                            Image(systemName: "xmark").foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
                }

                Group {
                    if store.loading && store.items.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView().tint(.orange)
                            Text("正在加载影视...").font(.footnote).foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = store.error, store.items.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundColor(.white.opacity(0.4))
                            Text(err).font(.footnote).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                            Button { Task { await store.reload() } } label: {
                                Text("重试").font(.subheadline.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 22).padding(.vertical, 9).background(Color.orange, in: Capsule())
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.items.isEmpty {
                        // 兜底：无数据且非加载/非错误时也要给提示，避免纯黑屏
                        VStack(spacing: 14) {
                            Image(systemName: "film.stack").font(.system(size: 40)).foregroundColor(.white.opacity(0.4))
                            Text("暂无影视内容").font(.footnote).foregroundColor(.white.opacity(0.6))
                            Button { Task { await store.reload() } } label: {
                                Text("重新加载").font(.subheadline.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 22).padding(.vertical, 8).background(Color.orange, in: Capsule())
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(store.items) { item in
                                    Button {
                                        Task { await openDetail(id: item.id, source: item.source ?? "") }
                                    } label: {
                                        VodPosterCell(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(12)

                            if store.hasMore {
                                HStack(spacing: 8) {
                                    if store.loadingMore { ProgressView().tint(.orange) }
                                    Button {
                                        Task { await store.loadMore() }
                                    } label: {
                                        Text(store.loadingMore ? "加载中..." : "加载更多（已显示 \(store.items.count) 部）")
                                            .font(.footnote).foregroundColor(.orange)
                                    }
                                }
                                .padding(.vertical, 18)
                            } else if !store.items.isEmpty {
                                Text("共 \(store.items.count) 部").font(.footnote)
                                    .foregroundColor(.secondary).padding(.vertical, 18)
                            }
                        }
                        .refreshable { await store.reload() }
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("影视")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSearch) {
                VodSearchView { item in
                    showSearch = false
                    Task { await openDetail(id: item.id, source: item.source ?? "") }
                }
            }
            // 用 item 绑定：selectedDetail 有值才弹出，且 detail 直接作为参数传入，
            // 杜绝 isPresented + if let 在弹出瞬间 detail 尚未同步导致的空视图黑屏。
            .fullScreenCover(item: $selectedDetail) { detail in
                VodDetailView(detail: detail, initialEpisode: selectedEpisode)
                    .onDisappear { selectedDetail = nil }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            if store.categories.isEmpty { await store.loadCategories() }
            if store.items.isEmpty { await store.reload() }
        }
    }
}

// MARK: - 影视海报格

struct VodPosterCell: View {
    let item: Api.VodItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 用无原始尺寸的容器严格撑出 9:12 比例，避免图片自身尺寸影响每格高度
                Color.clear
                    .aspectRatio(9.0 / 12.0, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: URL(string: item.cover ?? "")) { phase in
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
                        .clipped()
                    }
                    .clipped()
                    .cornerRadius(10)

                if !(item.remarks ?? "").isEmpty {
                    Text(item.remarks ?? "")
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(5)
                        .lineLimit(1)
                }
            }
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                // 限制宽度让文字按列宽换行，垂直方向按内容撑开，不设固定高度（否则长标题会被压缩重叠）
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            let year = item.year ?? ""
            let typeName = item.typeName ?? ""
            if !year.isEmpty || !typeName.isEmpty {
                Text([year, typeName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - 影视搜索页

struct VodSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Api.VodItem) -> Void
    @State private var text = ""
    @State private var results: [Api.VodItem] = []
    @State private var searching = false
    @State private var searched = false
    @State private var err: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.white.opacity(0.5))
                        TextField("搜索电影 / 电视剧 / 演员", text: $text)
                            .foregroundColor(.white)
                            .submitLabel(.search)
                            .focused($fieldFocused)
                            .onSubmit { fieldFocused = false; doSearch() }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    Button { fieldFocused = false; doSearch() } label: {
                        Text("搜索").foregroundColor(.orange)
                    }
                }
                .padding(12)

                Group {
                    if searching {
                        ProgressView().tint(.orange).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let e = err {
                        Text(e).font(.footnote).foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searched && results.isEmpty {
                        Text("没有搜到「\(text)」，换个词试试").font(.footnote)
                            .foregroundColor(.white.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !results.isEmpty {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                                ForEach(results) { item in
                                    Button { onSelect(item) } label: { VodPosterCell(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }.padding(12)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 44)).foregroundColor(.white.opacity(0.3))
                            Text("输入片名或演员搜索影视").font(.footnote).foregroundColor(.white.opacity(0.5))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("搜索影视").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func doSearch() {
        let kw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        searching = true; err = nil; searched = true; results = []
        Task {
            do {
                let list = try await Api.vodList(cat: "all", page: 1, keyword: kw, source: VodStore.shared.source)
                results = list.items
            } catch let e {
                err = "搜索失败：\(e.localizedDescription)"
            }
            searching = false
        }
    }
}

// MARK: - 影视数据层

@MainActor
final class VodStore: ObservableObject {
    static let shared = VodStore()
    @Published var categories: [Api.VodCategory] = []
    @Published var category = "movie"
    @Published var sources: [Api.VodSource] = []
    // 当前线路；空字符串=自动（服务端按可用性挑第一个）。记住用户选择。
    @Published var source: String = {
        let s = UserDefaults.standard.string(forKey: "vodSource") ?? ""
        return s  // 空=自动
    }() {
        didSet { UserDefaults.standard.set(source, forKey: "vodSource") }
    }
    @Published var items: [Api.VodItem] = []
    @Published var page = 1
    @Published var pagecount = 1
    @Published var loading = false
    @Published var loadingMore = false
    @Published var error: String?

    var hasMore: Bool { page < pagecount }

    func loadCategories() async {
        do { categories = try await Api.vodCategories() }
        catch { /* 分类失败不影响主流程 */ }
        do { sources = try await Api.vodSources() }
        catch { /* 线路列表失败不影响主流程 */ }
    }

    /// 切换线路并重新加载
    func switchSource(_ key: String) async {
        guard key != source else { return }
        source = key
        await reload()
    }

    func switchCategory(_ key: String) async {
        guard key != category else { return }
        category = key
        await reload()
    }

    func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let list = try await Api.vodList(cat: category, page: 1, source: source)
            items = list.items
            page = list.page ?? 1
            pagecount = list.pagecount ?? 1
        } catch let e {
            error = "加载失败：\(e.localizedDescription)"
        }
    }

    func loadMore() async {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = page + 1
            let list = try await Api.vodList(cat: category, page: next, source: source)
            // 去重追加
            var seen = Set(items.map { $0.id })
            for it in list.items where !seen.contains(it.id) {
                items.append(it); seen.insert(it.id)
            }
            page = list.page ?? next
            pagecount = list.pagecount ?? pagecount
        } catch { /* 翻页失败静默，保留已有 */ }
    }
}

// MARK: - 影视详情页（简介 + 选集 → 全屏播放）

struct VodDetailView: View {
    let detail: Api.VodDetail
    let initialEpisode: Int
    @Environment(\.dismiss) private var dismiss
    @State private var playingEpisode: Int?
    @State private var playFromSelection = false   // 是否从选集入口进入（不续播，尊重所选集）
    @State private var showPlayer = false
    @State private var showEpisodes = false

    var body: some View {
        // 关键：fullScreenCover 内不再嵌套 NavigationView（SwiftUI 已知渲染坑，
        // 弹出瞬间内容 view 高度可能为 0 导致整页纯黑）。改用纯 ZStack + 自定义顶栏。
        ZStack {
            Color.black.ignoresSafeArea()
            if detail.episodes.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundColor(.white.opacity(0.4))
                    Text("该片暂无可用播放源").foregroundColor(.white.opacity(0.7))
                    Button { dismiss() } label: {
                        Text("返回").foregroundColor(.white).padding(.horizontal, 24).padding(.vertical, 9)
                            .background(Color.orange, in: Capsule())
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                            // 顶部：封面 + 标题 + 元信息
                            HStack(alignment: .top, spacing: 14) {
                                AsyncImage(url: URL(string: detail.cover ?? "")) { phase in
                                    if case .success(let img) = phase { img.resizable().scaledToFill() }
                                    else { Color(.systemGray5).opacity(0.3) }
                                }
                                .frame(width: 110, height: 150)
                                .clipped().cornerRadius(10)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(detail.title).font(.title3.bold()).foregroundColor(.white)
                                    let year = detail.year ?? ""
                                    let typeName = detail.typeName ?? ""
                                    let area = detail.area ?? ""
                                    if !year.isEmpty || !typeName.isEmpty || !area.isEmpty {
                                        Text([year, typeName, area].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundColor(.orange)
                                    }
                                    if !(detail.remarks ?? "").isEmpty {
                                        Text(detail.remarks ?? "").font(.caption).foregroundColor(.white.opacity(0.7))
                                    }
                                    let score = detail.score ?? ""
                                    if !score.isEmpty && score != "0" {
                                        HStack(spacing: 3) {
                                            Image(systemName: "star.fill").foregroundColor(.yellow)
                                            Text(score).foregroundColor(.white)
                                        }.font(.caption)
                                    }
                                }
                            }

                            // 播放按钮
                            Button {
                                playingEpisode = initialEpisode
                                playFromSelection = false
                                showPlayer = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                    Text(detail.episodes.count > 1 ? "播放第1集" : "立即播放")
                                }
                                .font(.subheadline.bold()).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                            }

                            // 选集
                            if detail.episodes.count > 1 {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("选集").font(.headline).foregroundColor(.white)
                                        Spacer()
                                        Button { showEpisodes.toggle() } label: {
                                            Text(showEpisodes ? "收起" : "全部 \(detail.episodes.count) 集")
                                                .font(.caption).foregroundColor(.orange)
                                        }
                                    }
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                                        ForEach(detail.episodes) { ep in
                                            Button {
                                                playingEpisode = ep.index
                                                playFromSelection = true
                                                showPlayer = true
                                            } label: {
                                                Text("\(ep.index + 1)")
                                                    .font(.system(size: 13))
                                                    .frame(maxWidth: .infinity).frame(height: 36)
                                                    .background(Color.white.opacity(0.12))
                                                    .foregroundColor(.white).cornerRadius(6)
                                            }
                                        }
                                    }
                                }
                            }

                            // 演员/导演
                            let actors = detail.actors ?? ""
                            let director = detail.director ?? ""
                            let content = detail.content ?? ""
                            if !actors.isEmpty {
                                Text("主演：\(actors)").font(.caption).foregroundColor(.white.opacity(0.6))
                            }
                            if !director.isEmpty {
                                Text("导演：\(director)").font(.caption).foregroundColor(.white.opacity(0.6))
                            }

                            // 简介
                            if !content.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("简介").font(.headline).foregroundColor(.white)
                                    Text(content).font(.subheadline).foregroundColor(.white.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(16)
                        .padding(.top, 46)   // 给自定义顶栏留位置
                    }
                }
                // 自定义顶栏（不再依赖 NavigationView）：只占自身高度，不拦截下方滚动
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white).padding(8).background(Color.black.opacity(0.5), in: Circle())
                        }
                        Spacer()
                        Text(detail.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                        Spacer()
                        Button("完成") { dismiss() }.foregroundColor(.orange)
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                    .background(Color.black.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fullScreenCover(isPresented: $showPlayer) {
                VodPlayerView(detail: detail, episodeIndex: playingEpisode ?? 0, resume: !playFromSelection, onClose: { showPlayer = false })
            }
        }
    }

// MARK: - 影视播放器（AVPlayer 直接播 m3u8，上下滑切集）

// 加载状态：KVO 回调写入。用引用类型避免闭包捕获 SwiftUI View 值类型造成引用循环。
private final class VodLoadState: ObservableObject {
    enum Phase {
        case loading
        case ready
        case failed(String)
    }
    @Published var phase: Phase = .loading
}

struct VodPlayerView: View {
    let detail: Api.VodDetail
    @State private var currentIndex: Int
    let resume: Bool   // true=播放按钮进入(续播上次进度)；false=选集进入(播放用户所选集)
    let onClose: () -> Void
    @State private var player: AVPlayer?
    @State private var showEpisodes = false
    @State private var showControls = false
    @State private var tip: String?
    @StateObject private var loadState = VodLoadState()
    @State private var itemObserver: NSKeyValueObservation?
    @State private var failObserver: NSObjectProtocol?
    @State private var currentEpisodes: [Api.VodEpisode] = []
    @State private var triedSources: Set<String> = []
    @State private var isFullscreen = false
    @State private var isPlaying = true
    @State private var showSeekBar = true
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?

    init(detail: Api.VodDetail, episodeIndex: Int, resume: Bool = true, onClose: @escaping () -> Void) {
        self.detail = detail
        self._currentIndex = State(initialValue: episodeIndex)
        self._currentEpisodes = State(initialValue: detail.episodes)
        var tried: Set<String> = []
        if let s = detail.source, !s.isEmpty { tried.insert(s) }
        self._triedSources = State(initialValue: tried)
        self.resume = resume
        self.onClose = onClose
    }

    private var isFailed: Bool {
        if case .failed = loadState.phase { return true }
        return false
    }

    private var progressKey: String { "vod_progress_\(detail.source ?? "")_\(detail.id)" }

    // 全屏按钮：在横屏与竖屏之间切换
    private func toggleFullscreen() {
        let enter = !isFullscreen
        isFullscreen = enter
        VodOrientation.lock(enter ? .landscapeRight : .portrait)
    }

    // 播放/暂停切换
    private func togglePlay() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                AVPlayerLayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)  // 关键：铺满 ZStack，否则 UIView 固有尺寸为0导致黑屏
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
            }

            // 加载中：显示转圈，避免加密流首帧解码期间纯黑屏以为坏了
            if case .loading = loadState.phase {
                VStack(spacing: 12) {
                    ProgressView().tint(.orange).scaleEffect(1.4)
                    Text("正在加载，请稍候…").font(.caption).foregroundColor(.white.opacity(0.7))
                }
            }

            // 加载失败：显示原因 + 重试，不再无限黑屏
            if case .failed(let msg) = loadState.phase {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 42)).foregroundColor(.white.opacity(0.5))
                    Text(msg).font(.subheadline).foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                    HStack(spacing: 14) {
                        Button { retryCurrent() } label: {
                            Text("重试").font(.subheadline.bold()).foregroundColor(.white)
                                .padding(.horizontal, 22).padding(.vertical, 8)
                                .background(Color.white.opacity(0.18), in: Capsule())
                        }
                        Button { triedSources.removeAll(); tryNextSource() } label: {
                            Text("换线路").font(.subheadline.bold()).foregroundColor(.white)
                                .padding(.horizontal, 22).padding(.vertical, 8)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                }
            }

            // 中间播放/暂停按钮（暂停时显示；加载失败时隐藏避免与错误提示重叠）
            if let player, !isPlaying, !isFailed {
                Button { togglePlay() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(28)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
                .allowsHitTesting(true)
            }

            if let tip {
                VStack {
                    Spacer()
                    Text(tip).font(.subheadline).foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.7), in: Capsule())
                    Spacer()
                }.allowsHitTesting(false)
            }

            // 顶部信息 + 返回（父级不设 allowsHitTesting，保证按钮可点）
            VStack {
                HStack(alignment: .top) {
                    Button { onClose() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white).padding(10).background(Color.black.opacity(0.5), in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                        Text(detail.episodes.count > 1
                             ? "第 \(currentIndex + 1) 集 / 共 \(detail.episodes.count) 集"
                             : (detail.episodes.first?.title ?? ""))
                            .font(.caption).foregroundColor(.white.opacity(0.75))
                    }
                    .allowsHitTesting(false)
                    Spacer()
                    Button { toggleFullscreen() } label: {
                        Image(systemName: isFullscreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white).padding(10)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                MarqueeView()
                    .padding(.top, 2)
                Spacer()
            }

            // 底部操作栏
            VStack {
                Spacer()
                HStack(spacing: 26) {
                    Spacer()
                    Button { play(index: currentIndex - 1) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "backward.fill").font(.system(size: 22))
                            Text("上一集").font(.caption2)
                        }.foregroundColor(.white)
                    }
                    Button { showEpisodes = true } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "list.bullet").font(.system(size: 24))
                            Text("选集").font(.caption2)
                        }.foregroundColor(.white)
                    }
                    Button { play(index: currentIndex + 1) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "forward.fill").font(.system(size: 22))
                            Text("下一集").font(.caption2)
                        }.foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.bottom, 24)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 60).onEnded { v in
                let dy = v.translation.height
                guard abs(dy) > 80, abs(dy) > abs(v.translation.width) else { return }
                if dy < 0 { play(index: currentIndex + 1) } else { play(index: currentIndex - 1) }
            }
        )
        // 加载失败自动换线路：常驻监听，视图重建也不漏；无候选线路时不再触发避免死循环
        .onReceive(loadState.$phase) { phase in
            if case .failed = phase {
                let remaining = ["hn", "wj", "bd", "gs", "jy", "js"].filter { !triedSources.contains($0) }
                if !remaining.isEmpty { tryNextSource() }
            }
        }
        .sheet(isPresented: $showEpisodes) {
            VodEpisodeSheet(detail: detail, currentIndex: currentIndex) { idx in
                showEpisodes = false
                play(index: idx)
            }
        }
        .task {
            var start = currentIndex
            // 仅"播放按钮"入口续播；从选集进入时尊重用户所选集数，不被上次进度覆盖
            if resume,
               let saved = UserDefaults.standard.object(forKey: progressKey) as? Int,
               detail.episodes.indices.contains(saved) {
                start = saved
            }
            play(index: start)
        }
        .onDisappear {
            UserDefaults.standard.set(currentIndex, forKey: progressKey)
            // 修复 H4：视图销毁前移除最后一条播放结束观察者，
            // 否则通知中心强持有闭包（捕获 self），AVPlayer/视图无法释放，
            // 且 pop 后仍可能收到通知修改已销毁视图。
            if let obs = endObserver {
                NotificationCenter.default.removeObserver(obs)
                endObserver = nil
            }
            if let obs = failObserver {
                NotificationCenter.default.removeObserver(obs)
                failObserver = nil
            }
            itemObserver?.invalidate(); itemObserver = nil
            if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
            player?.pause()
            player?.rate = 0
            player?.replaceCurrentItem(with: nil)
            player = nil
            // 退出播放器恢复竖屏
            if isFullscreen { VodOrientation.lock(.portrait) }
        }
    }

    /// 用指定集数与线路构建播放器：带 KVO 加载状态 + 失败自动换线路
    private func play(index: Int, source: String? = nil) {
        let eps = currentEpisodes
        guard eps.indices.contains(index) else {
            showTip(index > currentIndex ? "已经是最后一集了" : "已经是第一集了")
            return
        }
        currentIndex = index
        UserDefaults.standard.set(index, forKey: progressKey)
        let urlString = eps[index].url
        guard let url = URL(string: urlString) else {
            loadState.phase = .failed("播放地址无效")
            return
        }

        // 切集/重试前彻底清理旧观察者与旧播放器，避免累积和串台
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        if let obs = failObserver { NotificationCenter.default.removeObserver(obs); failObserver = nil }
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        itemObserver?.invalidate(); itemObserver = nil
        player?.pause()
        player?.rate = 0
        player?.replaceCurrentItem(with: nil)

        loadState.phase = .loading
        isPlaying = true
        let newPlayer = AVPlayer(url: url)
        player = newPlayer

        // 关键：监听 item.status，只有真正 readyToPlay 才撤掉加载转圈；
        // 加密流首帧解码慢或失败时不再纯黑屏。KVO 闭包捕获引用类型的 loadState，不捕获 View。
        let state = loadState
        itemObserver = newPlayer.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    if case .loading = state.phase { state.phase = .ready }
                case .failed:
                    state.phase = .failed(item.error?.localizedDescription ?? "播放失败，可点重试或切换线路")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        // 解码中途失败（如分片 403/网络中断）也给出提示，而不是一直黑屏
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: newPlayer.currentItem, queue: .main
        ) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            state.phase = .failed("播放出错：\(err?.localizedDescription ?? "可切换线路重试")")
        }

        // 同步真实播放状态：来电/切后台致系统暂停后，中央播放键要正确出现
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak newPlayer] _ in
            if let p = newPlayer { self.isPlaying = p.timeControlStatus == .playing }
        }
        newPlayer.play()

        // 播放结束自动下一集
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem, queue: .main
        ) { _ in
            if index < self.currentEpisodes.count - 1 { self.play(index: index + 1) }
        }
        showTip(eps.count > 1 ? "第 \(index + 1) 集" : eps[index].title)
    }

    /// 点「重试」：重新拉当前线路当前集
    private func retryCurrent() {
        loadState.phase = .loading
        Task {
            do {
                let src = detail.source ?? "hn"
                let fresh = try await Api.vodDetail(id: detail.id, source: src)
                await MainActor.run {
                    self.currentEpisodes = fresh.episodes
                    self.play(index: self.currentIndex, source: src)
                }
            } catch {
                await MainActor.run { self.loadState.phase = .failed("重试失败：\(error.localizedDescription)") }
            }
        }
    }

    /// 当前线路加载失败时自动尝试其它线路
    private func tryNextSource() {
        let all = ["hn", "wj", "bd", "gs", "jy", "js"]
        guard let next = all.first(where: { !triedSources.contains($0) }) else {
            loadState.phase = .failed("所有线路均无法播放，请稍后再试")
            return
        }
        triedSources.insert(next)
        loadState.phase = .loading
        Task {
            do {
                let fresh = try await Api.vodDetail(id: detail.id, source: next)
                guard !fresh.episodes.isEmpty else {
                    await MainActor.run { self.tryNextSource() }
                    return
                }
                await MainActor.run {
                    self.currentEpisodes = fresh.episodes
                    let idx = min(self.currentIndex, fresh.episodes.count - 1)
                    self.play(index: idx, source: next)
                    self.showTip("已切换线路，正在加载")
                }
            } catch {
                await MainActor.run { self.tryNextSource() }
            }
        }
    }

    private func showTip(_ text: String) {
        tip = text
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if tip == text { tip = nil }
        }
    }
}

// MARK: - 影视选集抽屉

struct VodEpisodeSheet: View {
    let detail: Api.VodDetail
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                    ForEach(detail.episodes) { ep in
                        Button {
                            onSelect(ep.index)
                        } label: {
                            Text("\(ep.index + 1)")
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity).frame(height: 42)
                                .background(ep.index == currentIndex ? Color.orange : Color(.systemGray5).opacity(0.4))
                                .foregroundColor(ep.index == currentIndex ? .white : .primary)
                                .cornerRadius(8)
                        }
                    }
                }.padding(14)
            }
            .navigationTitle("选集 · 共\(detail.episodes.count)集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}
