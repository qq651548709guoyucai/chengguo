import SwiftUI

// MARK: - 修改密码页
struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library = LibraryStore.shared

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showOld = false
    @State private var showNew = false
    @State private var busy = false
    @State private var message: String?
    @State private var succeeded = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("原密码", text: $oldPassword)
                    SecureField("新密码（至少 6 位）", text: $newPassword)
                    SecureField("确认新密码", text: $confirmPassword)
                } header: {
                    Text("账号：\(library.username)")
                } footer: {
                    Text("修改成功后无需重新登录，当前登录状态保持有效。")
                }

                if let msg = message {
                    Section {
                        Text(msg)
                            .foregroundColor(succeeded ? .green : .red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() }
                            Text("确认修改").bold()
                            Spacer()
                        }
                    }
                    .disabled(busy || oldPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty)
                }
            }
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(succeeded ? "完成" : "取消") { dismiss() }
                }
            }
            .onChange(of: succeeded) { ok in
                if ok {
                    // 成功后清空输入
                    oldPassword = ""
                    newPassword = ""
                    confirmPassword = ""
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func submit() async {
        message = nil
        guard newPassword.count >= 6 else {
            message = "新密码至少 6 位"
            return
        }
        guard newPassword == confirmPassword else {
            message = "两次输入的新密码不一致"
            return
        }
        guard newPassword != oldPassword else {
            message = "新密码不能和原密码相同"
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await library.changePassword(old: oldPassword, new: newPassword)
            succeeded = true
            message = "✅ 密码修改成功"
        } catch {
            if let e = error as? ApiError, case .server(let m) = e {
                message = m   // 直接显示服务端文案（如"原密码错误"）
            } else {
                message = "修改失败，请检查网络后重试"
            }
        }
    }
}
