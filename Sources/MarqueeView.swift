import SwiftUI

// MARK: - 跑马灯配置单例（拉取一次，全局复用）
final class MarqueeStore: ObservableObject {
    static let shared = MarqueeStore()
    @Published var config: MarqueeConfig?
    @Published private(set) var loaded = false

    func load(force: Bool = false) async {
        let need = await MainActor.run { !self.loaded || force }
        guard need else { return }
        do {
            let c = try await Api.marquee()
            await MainActor.run {
                self.config = c
                self.loaded = true
            }
        } catch {
            // 拉取失败静默降级：不显示跑马灯，不影响播放
            await MainActor.run { self.loaded = true }
        }
    }
}

// MARK: - 跑马灯视图（循环滚动字幕，常驻播放器顶部）
struct MarqueeView: View {
    @ObservedObject private var store = MarqueeStore.shared

    var body: some View {
        Group {
            if let c = store.config, c.enabled, !c.text.isEmpty {
                MarqueeScroller(config: c)
            }
        }
        .task { await store.load() }
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
                // 从屏幕右侧外进入，滚到左侧完全消失后循环
                let x = w - traveled.truncatingRemainder(dividingBy: total)
                Text(config.text)
                    .font(.system(size: font, weight: .semibold))
                    .foregroundColor(Color(hex: config.fontColor) ?? .white)
                    .fixedSize()
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
