import SwiftUI

// MARK: - 独立播放页（底部 Tab）
// 从首页/搜索/我的点剧集后跳到这里，全屏沉浸播放，顶部显示第几集

struct PlayView: View {
    @ObservedObject var store: DramaStore

    var body: some View {
        Group {
            if let drama = store.playingDrama {
                FeedCard(drama: drama, autoPlay: true)
                    .id(drama.id)   // 换剧时强制重建播放器
            } else {
                emptyState
            }
        }
        .background(Color.black)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.25))

            Text("还没有选择剧集")
                .font(.title3.bold())
                .foregroundColor(.white.opacity(0.85))

            Text("到「首页」或「搜索」挑一部剧\n点开就会在这里播放")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            Button {
                store.selectedTab = 0
            } label: {
                Text("去首页逛逛")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .background(Color.orange, in: Capsule())
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
