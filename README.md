# 橙果短剧 iOS 版（类红果短剧 App）

基于 **openhongguo**（红果短剧非官方 SDK 的 iOS 绑定，Swift Package）+ SwiftUI 实现的竖屏刷剧 App。
产出为**未签名 .ipa**，用「全能签」自签后安装。

## 功能

- 📱 抖音/红果式竖屏上下滑动刷剧（旋转 ScrollView 实现，兼容 iOS 15+）
- 🔍 剧名搜索 + 热搜词
- ▶️ AVPlayer 播放（默认 540p，播放地址来自红果接口，360p~1080p 可选）
- 📋 分集列表抽屉（游标翻页，支持 898 集长剧）
- ⏭️ 播完自动下一集
- 全程匿名设备，不需要红果账号

## 项目结构

```
hongguo-ios/
├── project.yml                          # xcodegen 工程描述
├── .github/workflows/build-ipa.yml      # GitHub Actions 云端构建未签名 ipa
└── Sources/
    ├── App.swift                        # App 入口 + 搜索/热搜 + 数据层
    ├── FeedView.swift                   # 竖屏信息流 + 播放卡片 + CardModel
    └── EpisodeSheet.swift               # 分集列表
```

## 方式一：GitHub Actions 云端构建（推荐，无 Mac 也能出 ipa）

1. 把本目录推到你自己的 GitHub **公开仓库**（公开仓库免费用 macOS runner）：

```bash
cd hongguo-ios
git init && git add -A && git commit -m "init"
git remote add origin https://github.com/<你的用户名>/chengguo.git
git push -u origin main
```

2. 打开仓库 → **Actions** → 等 `Build Unsigned IPA` 跑完（约 5~10 分钟）
3. 在本次运行页面的 **Artifacts** 下载 `ChengGuo-unsigned-ipa.zip`，解压得到 `ChengGuo-unsigned.ipa`
4. 传给全能签 → 选择证书 → 签名 → 安装

## 方式二：本地 Mac 构建

```bash
brew install xcodegen
cd hongguo-ios && xcodegen generate
open ChengGuo.xcodeproj      # Xcode 里选真机直接 Run
```

## 修改 App 名称 / Bundle ID

- App 显示名：`project.yml` → `CFBundleDisplayName`
- Bundle ID：`project.yml` → `bundleIdPrefix`（当前生成 `com.chengguo.ChengGuo`）

改完重新生成项目/重新触发 Actions 即可。

## 技术要点

- SDK 接入：Swift Package `https://github.com/beilunyang/openhongguo.git`（from 0.4.0），首次请求自动注册匿名设备
- 播放地址有时效签名（x-expires），按需获取、不要长期缓存
- 被风控时可调 `client.resetDevice()` 重置设备

## ⚠️ 免责声明

openhongguo 为红果私有接口的逆向封装，本项目仅供学习研究，禁止商业用途，内容版权归原权利方。
