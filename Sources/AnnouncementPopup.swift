import SwiftUI

// MARK: - 开屏公告弹窗（进入 App 自动弹出，支持多条翻页）

struct AnnouncementPopupView: View {
    let announcements: [Api.Announcement]
    let onDismiss: () -> Void
    @State private var current = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
                .onTapGesture { /* 点空白不关闭，避免误触 */ }

            VStack(spacing: 0) {
                // 顶部标题
                HStack(spacing: 8) {
                    Image(systemName: "megaphone.fill").foregroundColor(.orange)
                    Text("站内公告").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    if announcements.count > 1 {
                        Text("\(current + 1) / \(announcements.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)

                // 公告内容（多条可左右滑）
                if announcements.count > 1 {
                    TabView(selection: $current) {
                        ForEach(Array(announcements.enumerated()), id: \.element.id) { idx, a in
                            page(a).tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .frame(maxHeight: 420)
                } else if let first = announcements.first {
                    page(first)
                }

                // 关闭按钮
                Button {
                    onDismiss()
                } label: {
                    Text("我知道了")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: 460)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
        }
    }

    private func page(_ a: Api.Announcement) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    if a.pinned {
                        Text("置顶")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.red, in: Capsule())
                    }
                    Spacer()
                }
                Text(a.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(a.content)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Text(formatTime(a.createdAt))
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(20)
        }
    }

    private func formatTime(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts / 1000)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}
