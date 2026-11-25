import SwiftUI

// MARK: - 我的：收藏 + 观看历史（继续观看）

struct LibraryView: View {
    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var store = DramaStore.shared
    @State private var tab = 0   // 0 收藏 / 1 观看历史
    @State private var showAdmin = false
    @State private var showChangePassword = false
    @State private var showAnnouncements = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            accountHeader

            // 公告入口（所有用户可见）
            Button { showAnnouncements = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "megaphone.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("公告").font(.subheadline.bold()).foregroundColor(.white)
                        Text("版本更新 · 使用说明").font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4))
                }
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .sheet(isPresented: $showAnnouncements) {
                NavigationView {
                    AnnouncementsView()
                }
                .navigationViewStyle(.stack)
            }

            // 管理后台入口（管理员可见）
            if library.currentUser?.role == "admin" || library.username == "admin" {
                Button { showAdmin = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape.2.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("管理后台").font(.subheadline.bold()).foregroundColor(.white)
                            Text("用户管理 · 数据统计").font(.caption2).foregroundColor(.white.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4))
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .sheet(isPresented: $showAdmin) { AdminPanelView() }
            }

            Picker("", selection: $tab) {
                Text("我的收藏").tag(0)
                Text("观看历史").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if tab == 0 {
                favoritesView
            } else {
                historyView
            }
        }
        .background(Color.black)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accountHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: library.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 42))
                .foregroundColor(library.isLoggedIn ? .orange : .white.opacity(0.4))

            VStack(alignment: .leading, spacing: 3) {
                if library.isLoggedIn {
                    Text(library.username).font(.headline).foregroundColor(.white)
                    HStack(spacing: 4) {
                        if library.isSyncing {
                            ProgressView().scaleEffect(0.6)
                            Text("同步中...").font(.caption2)
                        } else {
                            Image(systemName: "icloud.fill").font(.caption2)
                            Text("数据已云同步").font(.caption2)
                        }
                    }
                    .foregroundColor(.white.opacity(0.5))
                } else {
                    Text("游客模式").font(.headline).foregroundColor(.white)
                    Text("数据仅存本机，登录可云同步").font(.caption2).foregroundColor(.white.opacity(0.5))
                }
            }
            Spacer()

            if library.isLoggedIn {
                HStack(spacing: 8) {
                    Button { showChangePassword = true } label: {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    Button {
                        library.logout()
                    } label: {
                        Text("退出").font(.caption).foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
                .sheet(isPresented: $showChangePassword) { ChangePasswordView() }
            } else {
                Button {
                    // 触发登录：把 didEnterApp 置 false，根视图会显示登录页
                    library.guestMode = false
                } label: {
                    Text("登录").font(.caption.bold()).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color.orange, in: Capsule())
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
    }

    // MARK: 收藏九宫格
    private var favoritesView: some View {
        Group {
            if library.favorites.isEmpty {
                emptyView(icon: "heart", text: "还没有收藏\n在播放页点「收藏」，下次好找")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(library.favorites) { drama in
                            Button {
                                store.openPlayer(drama)
                            } label: {
                                PosterCell(drama: drama)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    library.removeFavorite(drama.id)
                                } label: {
                                    Label("取消收藏", systemImage: "heart.slash")
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: 观看历史列表（带进度）
    private var historyView: some View {
        Group {
            if library.sortedWatch().isEmpty {
                emptyView(icon: "clock", text: "还没有观看记录\n看剧后会自动记住看到哪里")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(library.sortedWatch(), id: \.seriesId) { p in
                            historyRow(p)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func historyRow(_ p: WatchProgress) -> some View {
        HStack(spacing: 12) {
            Button {
                store.openPlayer(p.series)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: p.series.coverUrl)) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Color(.systemGray5).opacity(0.25)
                                .overlay(Image(systemName: "film").foregroundColor(.white.opacity(0.4)))
                        }
                    }
                    .frame(width: 62, height: 84)
                    .clipped()
                    .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.series.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(p.displayText)
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.9))

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.15))
                                Capsule().fill(Color.orange)
                                    .frame(width: geo.size.width * p.fraction)
                            }
                        }
                        .frame(height: 4)

                        Text("继续观看")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                library.removeWatch(p.seriesId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func emptyView(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))
            Text(text)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity)
    }
}
