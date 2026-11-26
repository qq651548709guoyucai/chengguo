import SwiftUI
import AVKit

// MARK: - 腾讯视频式播放器
// 用纯 AVPlayerLayer 做画面（无系统控件/PiP/AirPlay），叠加自定义控制条：
//   播放/暂停、可拖动进度、当前/总时长、快退快进 10 秒、倍速、清晰度、选集、全屏
//   单击显隐控件、上下滑切集、左右滑快进、播放中 5 秒自动隐藏控件
// 画面铺满全屏（含安全区），控制条留在安全区内 → 自动位于底部 TabBar 上方，不会被挡住。
struct TencentPlayerView: View {
    @ObservedObject var model: CardModel
    @State private var dragging = false
    @State private var seekValue: Double = 0

    var body: some View {
        ZStack {
            // 画面层：铺满全屏
            if let player = model.player {
                AVPlayerLayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.flashControls() }
                    .gesture(
                        DragGesture(minimumDistance: 55)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                if abs(dy) > abs(dx), abs(dy) > 80 {
                                    Task {
                                        if dy < 0 { await model.nextEpisode() }
                                        else { await model.prevEpisode() }
                                    }
                                    model.flashControls()
                                } else if abs(dx) > 80 {
                                    model.skip(dx < 0 ? 10 : -10)   // 左滑前进 / 右滑后退
                                    model.flashControls()
                                }
                            }
                    )
            } else {
                Color.black.ignoresSafeArea()
            }

            // 中央大播放按钮（暂停时）
            if model.player != nil && !model.isPlaying {
                Button { model.togglePlay() } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 66))
                        .foregroundColor(.white.opacity(0.92))
                        .shadow(radius: 8)
                }
                .transition(.scale.combined(with: .opacity))
            }

            // 加载 / 错误提示
            if let st = model.statusText {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(st).font(.footnote).foregroundColor(.white.opacity(0.85))
                }
            }

            // 控制条（留在安全区内 → 位于 TabBar 上方，可点）
            if model.player != nil && model.showControls {
                VStack {
                    Spacer()
                    controlBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showControls)
    }

    // MARK: 底部控制条
    private var controlBar: some View {
        VStack(spacing: 8) {
            // 进度条 + 时间
            HStack(spacing: 10) {
                Text(fmt(model.currentSeconds))
                Slider(value: Binding(
                    get: { dragging ? seekValue : model.currentSeconds },
                    set: { v in if dragging { seekValue = v } }
                ), in: 0...max(model.totalSeconds, 1), onEditingChanged: { editing in
                    dragging = editing
                    if editing { seekValue = model.currentSeconds }
                    else { model.seek(to: seekValue) }
                })
                .tint(.orange)
                Text(fmt(model.totalSeconds))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .monospacedDigit()

            // 功能按钮行
            HStack(spacing: 15) {
                // 播放/暂停
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                // 快退 10 秒
                Button { model.skip(-10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 21))
                }
                // 快进 10 秒
                Button { model.skip(10) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 21))
                }

                Spacer(minLength: 2)

                // 倍速
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button {
                            model.setSpeed(Float(r))
                        } label: {
                            HStack {
                                Text(speedText(Float(r)))
                                if abs(model.speed - Float(r)) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(model.speed >= 0.99 && model.speed <= 1.01 ? "倍速" : speedText(model.speed))
                        .font(.system(size: 13, weight: .semibold))
                }

                // 清晰度
                Button { model.showQuality = true } label: {
                    Text(model.quality)
                        .font(.system(size: 12, weight: .semibold))
                }

                // 选集
                Button { model.showEpisodes = true } label: {
                    Image(systemName: "list.bullet").font(.system(size: 20))
                }

                // 全屏
                Button { model.toggleFullScreen() } label: {
                    Image(systemName: model.fullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 19))
                }
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func speedText(_ s: Float) -> String {
        String(format: "%gx", s)
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s)
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
