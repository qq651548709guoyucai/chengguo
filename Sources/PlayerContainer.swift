import SwiftUI
import AVKit

// MARK: - 纯 AVPlayerLayer 画面
// 只渲染视频画面，不含任何系统控件：
//  - 天然没有画中画(PiP)/AirPlay 图标
//  - 不像 AVPlayerViewController 那样会自动全屏 present 把 SwiftUI 覆盖层吞掉导致黑屏
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.player !== player { uiView.player = player }
    }

    final class PlayerLayerUIView: UIView {
        var player: AVPlayer? {
            didSet { playerLayer.player = player }
        }
        private let playerLayer = AVPlayerLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            // 用 autoresizingMask 保证无论父视图如何布局，layer 都跟随铺满
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = frame
            layer.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 用整个 view 的 bounds 铺满，避免 bounds 为 0 时黑屏
            playerLayer.frame = bounds
        }
    }
}

// MARK: - 强制旋转屏幕（全屏播放）
enum VodOrientation {
    static func lock(_ orientation: UIInterfaceOrientation) {
        if #available(iOS 16.0, *) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
            let mask: UIInterfaceOrientationMask = orientation == .landscapeRight ? .landscapeRight : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
