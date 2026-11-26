import SwiftUI

// MARK: - 评论区（按剧）：发评论 / 回复 / 删除（本人或管理员）
struct CommentsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library = LibraryStore.shared
    let seriesId: String
    let seriesTitle: String

    @State private var comments: [Api.Comment] = []
    @State private var input = ""
    @State private var replyTo: Api.Comment? = nil     // 正在回复的评论
    @State private var currentUserId = ""
    @State private var currentRole = ""
    @State private var busy = false
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 评论列表
                if loading {
                    Spacer()
                    ProgressView().tint(.orange)
                    Spacer()
                } else if comments.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 44)).foregroundColor(.white.opacity(0.3))
                        Text("还没有评论\n来发第一条吧").font(.subheadline)
                            .foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(topLevel) { c in
                                commentBlock(c)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }

                if let msg = message {
                    Text(msg).font(.caption).foregroundColor(.orange)
                        .padding(.horizontal).padding(.bottom, 4)
                }

                // 输入区
                if replyTo != nil {
                    HStack(spacing: 6) {
                        Text("回复 @\(replyTo!.displayName)").font(.caption).foregroundColor(.orange)
                        Spacer()
                        Button { replyTo = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 8)
                }

                HStack(spacing: 10) {
                    TextField("说点什么...", text: $input)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.1), in: Capsule())

                    Button {
                        Task { await send() }
                    } label: {
                        if busy { ProgressView().tint(.white) }
                        else { Text("发送").font(.subheadline.bold()) }
                    }
                    .frame(width: 60, height: 40)
                    .background(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.3) : Color.orange, in: Capsule())
                    .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(Color.black.opacity(0.9))
            }
            .background(Color.black)
            .navigationTitle("评论 \(comments.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private var topLevel: [Api.Comment] { comments.filter { $0.parentId == nil || $0.parentId?.isEmpty == true } }
    private func replies(of c: Api.Comment) -> [Api.Comment] { comments.filter { $0.parentId == c.id } }

    private func commentBlock(_ c: Api.Comment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            commentRow(c, isReply: false)
            ForEach(replies(of: c)) { r in
                commentRow(r, isReply: true)
            }
        }
        .padding(.vertical, 10)
    }

    private func commentRow(_ c: Api.Comment, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isReply { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundColor(.white.opacity(0.3)) }
            // 用户头像（emoji）
            ZStack {
                Circle().fill(Color.orange.opacity(0.18)).frame(width: 34, height: 34)
                Text(c.avatarEmoji).font(.system(size: 19))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.displayName).font(.subheadline.bold()).foregroundColor(.orange)
                    if c.role == "admin" {
                        Text("管理员").font(.caption2).foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.5), in: Capsule())
                    }
                    if let to = c.replyTo {
                        Text("回复 @\(to)").font(.caption2).foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    Text(timeText(c.createdAt)).font(.caption2).foregroundColor(.white.opacity(0.35))
                }
                Text(c.text).font(.subheadline).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Button { replyTo = c; input = "" } label: {
                        Text("回复").font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                    if c.userId == currentUserId || currentRole == "admin" {
                        Button { Task { await remove(c) } } label: {
                            Text("删除").font(.caption2).foregroundColor(.red.opacity(0.8))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func timeText(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts / 1000)
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private func load() async {
        guard library.isLoggedIn, !library.token.isEmpty else {
            message = "请先登录后再使用评论功能"
            loading = false
            return
        }
        // 拿当前用户 id / role；token 失效则自动重登后重试
        do {
            var me: Api.AccountUser
            do {
                me = try await Api.getMe(token: library.token)
            } catch {
                let e = error as? ApiError
                if e?.isUnauthorized == true, await library.reLoginSilently() {
                    me = try await Api.getMe(token: library.token)
                } else {
                    throw error
                }
            }
            currentUserId = me.id
            currentRole = me.role
            comments = try await Api.comments(seriesId: seriesId, token: library.token)
        } catch {
            message = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 未登录（游客）无法发评论，给出明确提示
        guard library.isLoggedIn, !library.token.isEmpty else {
            message = "请先登录后再发表评论（在「我的」页登录）"
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await postWithAutoRelogin(text: text)
            input = ""
            replyTo = nil
            message = nil
            await load()   // 刷新列表
        } catch {
            let e = error as? ApiError
            if e?.isUnauthorized == true {
                message = "登录已过期，请在「我的」页重新登录"
            } else {
                message = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    /// 发评论；若 token 失效则自动用保存的账号密码重登后重试一次
    private func postWithAutoRelogin(text: String) async throws {
        do {
            try await Api.postComment(seriesId: seriesId, seriesTitle: seriesTitle,
                                      text: text, parentId: replyTo?.id, token: library.token)
        } catch {
            let e = error as? ApiError
            if e?.isUnauthorized == true, await library.reLoginSilently() {
                // 重登成功，用新 token 重试
                try await Api.postComment(seriesId: seriesId, seriesTitle: seriesTitle,
                                          text: text, parentId: replyTo?.id, token: library.token)
            } else {
                throw error
            }
        }
    }

    private func remove(_ c: Api.Comment) async {
        do {
            try await Api.deleteComment(id: c.id, token: library.token)
            await load()
        } catch {
            message = "删除失败，请重试"
        }
    }
}
