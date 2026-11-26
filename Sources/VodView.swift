import SwiftUI
import AVKit

// MARK: - 影视 Tab 根视图（分类浏览 + 搜索）

struct VodView: View {
    @StateObject private var store = VodStore.shared
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var selectedDetail: Api.VodDetail?
    @State private var showDetail = false
    @State private var selectedEpisode = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

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
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(store.items) { item in
                                    Button {
                                        Task {
                                            if let d = try? await Api.vodDetail(id: item.id, source: item.source ?? "") {
                                                selectedDetail = d
                                                selectedEpisode = 0
                                                showDetail = true
                                            }
                                        }
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
                    Task {
                        if let d = try? await Api.vodDetail(id: item.id, source: item.source ?? "") {
                            selectedDetail = d
                            selectedEpisode = 0
                            showDetail = true
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showDetail) {
                if let detail = selectedDetail {
                    VodDetailView(detail: detail, initialEpisode: selectedEpisode)
                }
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
                .frame(maxWidth: .infinity)
                .aspectRatio(9.0 / 12.0, contentMode: .fill)
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
                .foregroundColor(.white).lineLimit(2)
                .frame(height: 34, alignment: .top)
            let year = item.year ?? ""
            let typeName = item.typeName ?? ""
            if !year.isEmpty || !typeName.isEmpty {
                Text([year, typeName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundColor(.white.opacity(0.5)).lineLimit(1)
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

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.white.opacity(0.5))
                        TextField("搜索电影 / 电视剧 / 演员", text: $text)
                            .foregroundColor(.white)
                            .submitLabel(.search)
                            .onSubmit { doSearch() }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    Button("搜索") { doSearch() }.foregroundColor(.orange)
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
                let list = try await Api.vodList(cat: "all", page: 1, keyword: kw)
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
            let list = try await Api.vodList(cat: category, page: 1)
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
            let list = try await Api.vodList(cat: category, page: next)
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
    @State private var showPlayer = false
    @State private var showEpisodes = false

    var body: some View {
        NavigationView {
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
                    }
                }
            }
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                VodPlayerView(detail: detail, episodeIndex: playingEpisode ?? 0, onClose: { showPlayer = false })
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 影视播放器（AVPlayer 直接播 m3u8，上下滑切集）

struct VodPlayerView: View {
    let detail: Api.VodDetail
    @State private var currentIndex: Int
    let onClose: () -> Void
    @State private var player: AVPlayer?
    @State private var showEpisodes = false
    @State private var showControls = false
    @State private var tip: String?
    @State private var loading = false
    @State private var isFullscreen = false
    @State private var isPlaying = true
    @State private var showSeekBar = true
    @State private var endObserver: NSObjectProtocol?

    init(detail: Api.VodDetail, episodeIndex: Int, onClose: @escaping () -> Void) {
        self.detail = detail
        self._currentIndex = State(initialValue: episodeIndex)
        self.onClose = onClose
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
            } else if loading {
                ProgressView().tint(.orange).scaleEffect(1.4)
            }

            // 中间播放/暂停按钮（暂停时显示）
            if let player, !isPlaying {
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
        .sheet(isPresented: $showEpisodes) {
            VodEpisodeSheet(detail: detail, currentIndex: currentIndex) { idx in
                showEpisodes = false
                play(index: idx)
            }
        }
        .task {
            var start = currentIndex
            // 断点续播：读取上次看到第几集
            if let saved = UserDefaults.standard.object(forKey: progressKey) as? Int,
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
            player?.pause()
            player = nil
            // 退出播放器恢复竖屏
            if isFullscreen { VodOrientation.lock(.portrait) }
        }
    }

    private func play(index: Int) {
        guard detail.episodes.indices.contains(index) else {
            showTip(index > currentIndex ? "已经是最后一集了" : "已经是第一集了")
            return
        }
        currentIndex = index
        UserDefaults.standard.set(index, forKey: progressKey)
        let urlString = detail.episodes[index].url
        guard let url = URL(string: urlString) else {
            showTip("播放地址无效"); return
        }
        loading = true
        player?.pause()
        // 切集前移除旧的播放结束监听，避免累积
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        isPlaying = true
        newPlayer.play()
        loading = false
        // 播放结束自动下一集（无需 weak：self 为值类型，@State 包装器保证状态可更新）
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem, queue: .main
        ) { _ in
            if index < detail.episodes.count - 1 {
                self.play(index: index + 1)
            }
        }
        showTip(detail.episodes.count > 1 ? "第 \(index + 1) 集" : detail.episodes[index].title)
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
