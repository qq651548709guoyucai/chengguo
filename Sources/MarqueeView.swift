import SwiftUI

// MARK: - 跑马灯配置单例
// 关键修复：config 直接给内置默认值，不再用 nil。
// 旧版用 nil + .task 挂在空 Group 上，SwiftUI 不会为 EmptyView 建立 identity，
// .task 从不执行 → 永远拉不到配置 → 跑马灯永远不显示。现在无论网络如何都会显示默认字幕。
final class MarqueeStore: ObservableObject {
    static let shared = MarqueeStore()

    /// 内置默认配置，保证 App 一打开就有跑马灯
    @Published var config: MarqueeConfig = MarqueeConfig(
        enabled: true,
        text: "熬夜看短剧 每晚更新",
        speed: 60,
        fontSize: 15,
        fontColor: "#ffffff",
        background: "#000000",
        opacity: 0
    )

    private var didLoad = false

    /// 拉取后台配置覆盖默认值。用 onAppear 里的 Task 显式调用，不依赖视图修饰符时机。
    func load(force: Bool = false) async {
        guard !didLoad || force else { return }
        didLoad = true
        do {
            let c = try await Api.marquee()
            await MainActor.run {
                // 后台关掉或清空文字时，保留默认字幕，避免出现空白
                if c.enabled && !c.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.config = c
                }
            }
        } catch {
            // 拉取失败静默降级：继续显示内置默认字幕
        }
    }
}

// MARK: - 跑马灯视图（循环滚动字幕）
struct MarqueeView: View {
    @ObservedObject private var store = MarqueeStore.shared

    var body: some View {
        MarqueeScroller(config: store.config)
            // 用 onAppear 显式触发加载：视图一出现必定执行，不受内容是否为空影响
            .onAppear { Task { await store.load() } }
    }
}

private struct MarqueeScroller: View {
    let config: MarqueeConfig
    @State private var started = Date()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let w = geo.size.width
                let font = CGFloat(config.fontSize)
                let textW = approxWidth(config.text, font) + 40
                let total = max(w + textW, 1)
                let traveled = CGFloat(config.speed * ctx.date.timeIntervalSince(started))
                // 起始即贴右边缘可见，随后向左滚
                let x = w - (traveled + textW).truncatingRemainder(dividingBy: total)
                Text(config.text)
                    .font(.system(size: font, weight: .semibold))
                    .foregroundColor(Color(hex: config.fontColor) ?? .white)
                    .fixedSize()
                    // 先以左边缘为基准占满宽度，offset(x:) 才等同于文字左边缘坐标
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: x)
            }
        }
        .frame(height: CGFloat(config.fontSize) + 18)
        .clipped()
        .background(
            (Color(hex: config.background) ?? .black)
                .opacity(config.opacity)
        )
        .allowsHitTesting(false)   // 不拦截播放器的点击/滑动手势
    }

    /// 粗略估算文字宽度：中日韩字符宽≈字号，其余≈0.6 字号
    private func approxWidth(_ text: String, _ font: CGFloat) -> CGFloat {
        var w: CGFloat = 0
        for ch in text {
            let isCJK = ch.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            w += isCJK ? font : font * 0.6
        }
        return w
    }
}

// MARK: - 十六进制颜色解析
extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
