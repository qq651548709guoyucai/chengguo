import SwiftUI

// MARK: - 公告列表页（公开，无需登录）

struct AnnouncementsView: View {
    @State private var items: [Api.Announcement] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("加载公告中...").font(.caption).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundColor(.white.opacity(0.3))
                    Text(error).font(.subheadline).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }
                }
                .frame(maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "megaphone").font(.system(size: 48)).foregroundColor(.white.opacity(0.3))
                    Text("暂无公告").font(.subheadline).foregroundColor(.white.opacity(0.6))
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(items) { a in
                            card(a)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color.black)
        .navigationTitle("公告")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func card(_ a: Api.Announcement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: a.pinned ? "pin.fill" : "megaphone.fill")
                    .foregroundColor(a.pinned ? .red : .orange)
                Text(a.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
            }
            Text(a.content)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if a.pinned {
                    Text("置顶").font(.caption2).foregroundColor(.red.opacity(0.9))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(formatTime(a.createdAt))
                    .font(.caption2).foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(a.pinned ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            items = try await Api.announcements()
        } catch {
            self.error = "公告加载失败：\(error.localizedDescription)"
        }
    }

    private func formatTime(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts / 1000)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}
