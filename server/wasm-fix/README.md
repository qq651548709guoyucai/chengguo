# 红果取址签名修复 wasm（2026-11-26）

## 问题
2026-11-23 起红果播放接口返回 HTTP 200 + 空 body（`ANONYMOUS_LIMITED`），
榜单/搜索/分集正常，唯独取址失败。换 IP、换签名服务均无效。

## 根因（来自上游 PR #25，J3n5en/openhongguo，2026-11-25 验证）
`SignPlaybackPOST` 无条件删除 `x-medusa` 头。服务端要求变化：
- 11-10 前：播放请求带 medusa → 空响应，所以要删；
- 11-23 起：播放请求**必须带** medusa（字段21=369 的真机布局），不带 → 空响应。

## 本 wasm 的源码
基于 `J3n5en/openhongguo` 分支 `fix/playback-medusa`（commit 09a0160f）：
- `internal/protocol/sign/playback.go`：保留 x-medusa（不 delete）
- `medusa_v5.go`：`medusaDeviceStatus = 369`，真机设备布局（从 7.4.5.32 解码）
- 内置签名（无需 signer 服务）

## 编译方式
```bash
# 需要 Go >= 1.22（本次用 1.23.4）
cd <源码目录>
GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" \
  -o openhongguo.wasm ./bindings/node/wasm
# wasm_exec.js 必须用同版本 Go 的：$(go env GOROOT)/misc/wasm/wasm_exec.js
```

## 部署
替换 `node_modules/openhongguo/dist/` 下的 `openhongguo.wasm` 和 `wasm_exec.js`，
重启服务即可。备份在服务器 `/root/openhongguo-wasm-backup-20261126.wasm`。

## 验证结果
- 沙箱 + 服务器均成功取址，返回 360p~1080p 共 5 档 bytevc1 清晰度。
- `/api/play/<真实分集id>` 0.065s 返回完整 stream 列表。
