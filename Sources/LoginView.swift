import SwiftUI

// MARK: - 登录 / 注册页

struct LoginView: View {
    @ObservedObject var library = LibraryStore.shared
    @State private var mode = 0          // 0 登录 / 1 注册
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var errorMsg = ""
    @State private var busy = false
    @State private var showPassword = false
    @State private var remember = true
    // 注册用：名号 + 头像
    @State private var nickname = ""
    @State private var selectedAvatar = "🙂"
    private let avatars = ["🙂","😀","😎","🤩","🥳","😊","😍","🤗","😜","🤔","😴","🥰","😇","🤠","👻","🤖","🐱","🐶","🐼","🦊","🐻","🐯","🦁","🐸","🦄","🐙","🦋","🌸","⭐","🔥","💎","🎮","🍀","🌈","🚀","🏀"]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: 60)

                    // Logo
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.orange)
                        Text("熬夜看短剧")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                        Text("登录后收藏、进度可跨设备同步")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Spacer().frame(height: 44)

                    VStack(spacing: 16) {
                        Picker("", selection: $mode) {
                            Text("登录").tag(0)
                            Text("注册").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .colorMultiply(.orange)

                        field(icon: "person.fill", placeholder: "用户名", text: $username)

                        HStack {
                            field(icon: "lock.fill", placeholder: "密码（6位以上）", text: $password, secure: !showPassword)
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }

                        if mode == 1 {
                            field(icon: "lock.rotation", placeholder: "确认密码", text: $confirm, secure: !showPassword)

                            // 名号（昵称，App 内显示用，可与登录用户名不同）
                            field(icon: "person.text.rectangle", placeholder: "名号（选填，如：追剧达人）", text: $nickname)

                            // 头像选择（内置 emoji，点选即可）
                            VStack(alignment: .leading, spacing: 8) {
                                Text("选个头像").font(.caption).foregroundColor(.white.opacity(0.6))
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                                    ForEach(avatars, id: \.self) { emo in
                                        Button { selectedAvatar = emo } label: {
                                            Text(emo)
                                                .font(.system(size: 24))
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 38)
                                                .background(emo == selectedAvatar ? Color.orange.opacity(0.3) : Color.white.opacity(0.08),
                                                            in: RoundedRectangle(cornerRadius: 8))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(emo == selectedAvatar ? Color.orange : Color.clear, lineWidth: 2)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // 记住账号密码开关（仅登录模式显示）
                        if mode == 0 {
                            HStack(spacing: 8) {
                                Button { remember.toggle() } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: remember ? "checkmark.square.fill" : "square")
                                            .foregroundColor(remember ? .orange : .white.opacity(0.5))
                                        Text("记住账号密码").font(.caption)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                                Spacer()
                            }
                        }

                        if !errorMsg.isEmpty {
                            Text(errorMsg)
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task { await submit() }
                        } label: {
                            ZStack {
                                if busy { ProgressView().tint(.white) }
                                else {
                                    Text(mode == 0 ? "登录" : "注册并登录")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(busy)
                    }
                    .padding(.horizontal, 28)

                    Spacer()

                    Button {
                        // 游客模式：直接进入，数据存本地
                        library.enterGuest()
                    } label: {
                        Text("暂不登录，先逛逛")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // 自动填入记住的账号密码
            remember = library.rememberCredentials
            if library.rememberCredentials {
                username = library.savedUsername
                password = library.savedPassword
            }
        }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 20)
            if secure {
                SecureField(placeholder, text: text)
                    .foregroundColor(.white)
            } else {
                TextField(placeholder, text: text)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func submit() async {
        errorMsg = ""
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !password.isEmpty else {
            errorMsg = "请填写用户名和密码"; return
        }
        if mode == 1 && password != confirm {
            errorMsg = "两次密码不一致"; return
        }
        busy = true
        defer { busy = false }
        do {
            if mode == 0 {
                try await library.login(username: u, password: password)
            } else {
                let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                try await library.register(username: u, password: password, nickname: nick, avatar: selectedAvatar)
            }
            // 记住账号密码（按开关）
            library.rememberCredentials = remember
            UserDefaults.standard.set(remember, forKey: "cg_remember_v1")
            if remember {
                library.remember(username: u, password: password)
            } else {
                library.savedUsername = ""
                library.savedPassword = ""
                UserDefaults.standard.set("", forKey: "cg_saved_username_v1")
                UserDefaults.standard.removeObject(forKey: "cg_saved_password_v1")
                Keychain.delete()   // 修复 L4：关闭记住时同步清除钥匙串密码
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
