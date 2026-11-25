import SwiftUI

// MARK: - 分集列表抽屉

struct EpisodeSheet: View {
    @ObservedObject var model: CardModel
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(model.episodes.enumerated()), id: \.element.id) { index, ep in
                        let locked = model.isEpisodeLocked(index)
                        Button {
                            if locked {
                                // 受限集：提示登录，不关闭选集页
                                model.showLoginHint = true
                            } else {
                                Task {
                                    await model.play(at: index)
                                    dismiss()
                                }
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Text(ep.title.isEmpty ? "第\(index + 1)集" : ep.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(
                                        index == model.currentIndex
                                            ? Color.orange
                                            : (locked ? Color(.systemGray4).opacity(0.6) : Color(.systemGray5))
                                    )
                                    .foregroundColor(index == model.currentIndex ? .white : (locked ? .secondary : .primary))
                                    .cornerRadius(8)
                                if locked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Color.black.opacity(0.55), in: Circle())
                                        .offset(x: 3, y: -3)
                                }
                            }
                        }
                    }
                }
                .padding(14)

                if model.epHasMore {
                    Button {
                        Task { await model.loadEpisodes() }
                    } label: {
                        if model.epLoading {
                            ProgressView()
                        } else {
                            Text("加载更多（已加载 \(model.episodes.count) 集）")
                                .font(.footnote)
                        }
                    }
                    .disabled(model.epLoading)   // 修复 H3：加载中禁止重复点击
                    .padding(.bottom, 20)
                } else if !model.episodes.isEmpty {
                    Text("共 \(model.episodes.count) 集")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle(model.drama.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("解锁全部剧集", isPresented: $model.showLoginHint) {
            Button("去登录") {
                library.guestMode = false
                library.token = ""
                DramaStore.shared.selectedTab = 0
                dismiss()
            }
            Button("稍后再说", role: .cancel) {}
        } message: {
            Text("游客可免费试看前2集，登录后解锁全部剧集并同步收藏与进度。")
        }
        .task {
            if model.episodes.isEmpty { await model.loadEpisodes() }
        }
    }
}
