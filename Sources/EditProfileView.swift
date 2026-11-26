import SwiftUI

// MARK: - 编辑个人资料（名号 + 头像）
struct EditProfileView: View {
    @ObservedObject var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var avatar = "🙂"
    @State private var errorMsg = ""
    @State private var busy = false

    // 与服务端 auth.mjs 的头像白名单保持一致
    private let avatars = ["🙂","😀","😎","🤩","🥳","😊","😍","🤗","😜","🤔","😴","🥰","😇","🤠","👻","🤖","🐱","🐶","🐼","🦊","🐻","🐯","🦁","🐸","🦄","🐙","🦋","🌸","⭐","🔥","💎","🎮","🍀","🌈","🚀","🏀"]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        // 当前头像预览
                        ZStack {
                            Circle().fill(Color.orange.opacity(0.2)).frame(width: 84, height: 84)
                            Text(avatar).font(.system(size: 48))
                        }
                        .overlay(Circle().stroke(Color.orange.opacity(0.6), lineWidth: 2))
                        .padding(.top, 20)

                        // 名号输入
                        VStack(alignment: .leading, spacing: 8) {
                            Text("名号").font(.caption).foregroundColor(.white.opacity(0.6))
                            TextField("2~16字，中文/字母/数字/下划线", text: $nickname)
                                .foregroundColor(.white)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 14)
                                .frame(height: 46)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.horizontal, 20)

                        // 头像网格
                        VStack(alignment: .leading, spacing: 10) {
                            Text("选择头像").font(.caption).foregroundColor(.white.opacity(0.6))
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                                ForEach(avatars, id: \.self) { emo in
                                    Button { avatar = emo } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(emo == avatar ? Color.orange.opacity(0.25) : Color.white.opacity(0.08))
                                            Text(emo).font(.system(size: 26))
                                        }
                                        .frame(height: 46)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(emo == avatar ? Color.orange : Color.clear, lineWidth: 2)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        if !errorMsg.isEmpty {
                            Text(errorMsg).font(.caption).foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                        }

                        // 保存
                        Button {
                            Task { await save() }
                        } label: {
                            ZStack {
                                if busy { ProgressView().tint(.white) }
                                else { Text("保存").font(.headline).foregroundColor(.white) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(busy)
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }.foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            nickname = library.currentUser?.displayName ?? library.username
            avatar = library.currentUser?.avatarEmoji ?? "🙂"
        }
    }

    private func save() async {
        errorMsg = ""
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty && nick.count < 2 {
            errorMsg = "名号至少 2 个字"; return
        }
        if !nick.isEmpty && nick.count > 16 {
            errorMsg = "名号最多 16 个字"; return
        }
        busy = true
        defer { busy = false }
        do {
            try await library.updateProfile(nickname: nick, avatar: avatar)
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
