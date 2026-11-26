import SwiftUI

// MARK: - 动态页面（后台下发 JSON，原生渲染）
// 「发现」Tab 的全部内容由服务端 /api/pages 驱动。
// 后台改配置 → App 下拉刷新即生效，无需更新软件、无网页。
struct DynamicPagesView: View {
    @ObservedObject var store: DramaStore
    @State private var pages: [DynamicPage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedPage = 0

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if loading && pages.isEmpty {
                    ProgressView().tint(.orange)
                } else if let error, pages.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 46)).foregroundColor(.white.opacity(0.3))
                        Text(error).font(.subheadline).foregroundColor(.white.opacity(0.7))
                        Button { Task { await load() } } label: {
                            Text("重试").font(.subheadline.bold()).foregroundColor(.orange)
                        }
                    }
                } else {
                    pageContent
                }
            }
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await load(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").foregroundColor(.orange)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    private var pageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 多页面时顶部分段切换
                if pages.count > 1 {
                    Picker("", selection: $selectedPage) {
                        ForEach(pages.indices, id: \.self) { i in
                            Text(pages[i].name).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }

                if selectedPage < pages.count {
                    let sections = pages[selectedPage].sections
                    if sections.isEmpty {
                        emptyHint
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, sec in
                            sectionView(sec)
                        }
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .refreshable { await load(force: true) }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48)).foregroundColor(.white.opacity(0.25))
            Text("这里还没有内容").font(.headline).foregroundColor(.white.opacity(0.7))
            Text("到后台「动态页面」配置即可显示").font(.caption).foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    @ViewBuilder
    private func sectionView(_ sec: PageSection) -> some View {
        switch sec.type {
        case "text":   textSection(sec)
        case "notice": noticeSection(sec)
        case "button": buttonSection(sec)
        case "banner": bannerSection(sec)
        case "grid":   gridSection(sec)
        case "list":   listSection(sec)
        default:       EmptyView()
        }
    }

    // MARK: 标题文字
    private func textSection(_ sec: PageSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !sec.title.isEmpty {
                Text(sec.title).font(.title3.bold()).foregroundColor(.white)
            }
            if !sec.subtitle.isEmpty {
                Text(sec.subtitle).font(.caption).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: 公告条
    private func noticeSection(_ sec: PageSection) -> some View {
        Button { handle(sec.action) } label: {
            HStack(spacing: 10) {
                Image(systemName: "megaphone.fill").foregroundColor(.orange)
                Text(sec.text.isEmpty ? "公告" : sec.text)
                    .font(.subheadline).foregroundColor(.white.opacity(0.9))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer()
                if !sec.action.isEmpty {
                    Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4)).font(.caption)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    // MARK: 按钮组
    private func buttonSection(_ sec: PageSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sec.title.isEmpty {
                Text(sec.title).font(.headline).foregroundColor(.white)
            }
            let cols = max(1, min(4, sec.columns > 0 ? sec.columns : 3))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: cols), spacing: 10) {
                ForEach(Array(sec.items.enumerated()), id: \.offset) { _, item in
                    Button { handle(item.action) } label: {
                        Text(item.title.isEmpty ? "按钮" : item.title)
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    // MARK: 横幅（横向滚动大图）
    private func bannerSection(_ sec: PageSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sec.title.isEmpty {
                Text(sec.title).font(.headline).foregroundColor(.white).padding(.horizontal, 14)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(sec.items.enumerated()), id: \.offset) { _, item in
                        Button { handle(item.action) } label: {
                            ZStack(alignment: .bottomLeading) {
                                posterImage(item.cover)
                                    .frame(width: 280, height: 150)
                                    .clipped()
                                    .cornerRadius(12)
                                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                                    .cornerRadius(12)
                                Text(item.title).font(.subheadline.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.bottom, 10)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: 九宫格
    private func gridSection(_ sec: PageSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !sec.title.isEmpty {
                Text(sec.title).font(.headline).foregroundColor(.white).padding(.horizontal, 14)
            }
            let cols = max(1, min(4, sec.columns > 0 ? sec.columns : 3))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 12) {
                ForEach(Array(sec.items.enumerated()), id: \.offset) { _, item in
                    Button { handle(item.action) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            posterImage(item.cover)
                                .aspectRatio(9.0 / 12.0, contentMode: .fit)
                                .clipped().cornerRadius(10)
                            Text(item.title).font(.caption).foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle).font(.caption2).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 16)
    }

    // MARK: 列表（横向滚动竖版卡片）
    private func listSection(_ sec: PageSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sec.title.isEmpty {
                Text(sec.title).font(.headline).foregroundColor(.white).padding(.horizontal, 14)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(sec.items.enumerated()), id: \.offset) { _, item in
                        Button { handle(item.action) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                posterImage(item.cover)
                                    .frame(width: 110, height: 150)
                                    .clipped().cornerRadius(10)
                                Text(item.title).font(.caption).foregroundColor(.white.opacity(0.9))
                                    .frame(width: 110, alignment: .leading).lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.caption2).foregroundColor(.white.opacity(0.45))
                                        .frame(width: 110, alignment: .leading).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: 封面占位 + 异步加载
    @ViewBuilder
    private func posterImage(_ urlString: String) -> some View {
        ZStack {
            Color.white.opacity(0.08)
            if let url = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure: placeholderIcon
                    default: placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "film").font(.system(size: 26)).foregroundColor(.white.opacity(0.2))
    }

    // MARK: - 跳转动作分发
    private func handle(_ raw: String) {
        guard !raw.isEmpty else { return }
        switch PageAction(raw) {
        case .play(let id):
            // 用配置里的标题/封面构造最小 SeriesItem，播放页会按 id 拉分集
            let item = findItem(forAction: raw)
            let series = SeriesItem(
                id: id,
                title: item?.title ?? "剧集",
                coverUrl: item?.cover ?? "",
                description: item?.subtitle ?? "",
                episodeCount: 0
            )
            store.openPlayer(series)
        case .vod:
            // VodView 详情为内部状态，外部直接切到影视 Tab
            store.selectedTab = 3
        case .search(let kw):
            guard !kw.isEmpty else { return }
            store.searchText = kw
            store.selectedTab = 2
            Task { await store.search(kw) }
        case .tab(let n):
            store.selectedTab = min(max(n, 0), 4)
        case .url(let s):
            if let url = URL(string: s) { UIApplication.shared.open(url) }
        case .none:
            break
        }
    }

    /// 反查当前动作对应的条目，取标题/封面（只为展示用）
    private func findItem(forAction action: String) -> SectionItem? {
        guard selectedPage < pages.count else { return nil }
        for sec in pages[selectedPage].sections {
            for item in sec.items where item.action == action { return item }
        }
        return nil
    }

    // MARK: - 加载
    private func load(force: Bool = false) async {
        if force { error = nil }
        do {
            let data = try await Api.pages()
            await MainActor.run {
                pages = data.pages
                if selectedPage >= pages.count { selectedPage = 0 }
                error = nil
                loading = false
            }
        } catch let err {
            let msg = "配置加载失败：\(err.localizedDescription)"
            await MainActor.run {
                if pages.isEmpty { error = msg }
                loading = false
            }
        }
    }
}
