import SwiftUI
import WebKit

// MARK: - 内嵌管理后台（WKWebView 加载服务器 /admin 页面）
struct AdminPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0
    private let adminURL = "http://47.100.207.19/admin"

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                AdminWebView(url: URL(string: adminURL)!, reloadToken: reloadToken)
                    .background(Color.black)
            }
            .navigationTitle("管理后台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { reloadToken += 1 } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button {
                            if let u = URL(string: adminURL) { UIApplication.shared.open(u) }
                        } label: {
                            Image(systemName: "safari")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - WKWebView 包装
struct AdminWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastToken: Int = 0 }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }
}
