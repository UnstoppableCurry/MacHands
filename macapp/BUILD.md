# 构建 MacHands.app

## 前提

- macOS 13 或更新(App 本身要 13+:`SMAppService.mainApp` 是 13 才有的)。
- Xcode 命令行工具:`xcode-select --install`。不需要完整的 Xcode。
- 没有第三方依赖。`Package.swift` 里一个 `dependencies` 都没有,
  用到的全是系统框架:Foundation / AppKit / CryptoKit / Security /
  ServiceManagement / UserNotifications / CoreGraphics / ImageIO。

检查一下:

```sh
swift --version          # 需要 Swift 5.9 或更新
xcode-select -p          # 要能打印出一个路径
```

## 构建与测试

```sh
cd macapp
swift build              # debug
swift test               # 协议层与加密层的测试
swift build -c release   # release
```

`swift test` 会读 `../shared/PROTOCOL-VECTORS.json`(agent 侧生成的互通向量)。
文件不在时那一组测试会**跳过**而不是失败,输出里会写明跳过的原因 ——
"全绿"不代表验过互通,看一眼跳过了几个。

## 打成 .app

```sh
./scripts/build-app.sh                 # dist/MacHands.app,未签名
./scripts/build-app.sh --sign adhoc    # ad-hoc 签名,只在本机有效
./scripts/build-app.sh --install       # 顺手拷进 /Applications
```

未签名或 ad-hoc 签名的 App 第一次打开要**右键 → 打开**,Gatekeeper 只问这一次。

跑起来之后:

- 菜单栏出现一只手。**没有 Dock 图标**,这是设计(`LSUIElement=true`)。
- 首次启动会自动打开唯一的那个窗口。点「复制给 agent」。
- 日志:`~/Library/Logs/MacHands/app.log`
- 审计:`~/Library/Logs/MacHands/audit.log`(JSONL,一行一条命令)
- 配置:`~/Library/Application Support/MacHands/settings.json`(不含私钥)
- 私钥:Keychain,service `app.machands.MacHands`。
  从 `.build/release/MacHands` 直接跑(没有 .app bundle)时 Keychain 会失败,
  这时会退到 UserDefaults 并在 app.log 里留痕 —— 调试可以,发布不行。

从 `.build` 里直接跑还有两处会**明确降级**:开机自启注册不了(需要 bundle),
通知发不出去(`UNUserNotificationCenter` 需要 bundle id)。两者都会写日志,不会崩。

## 发布(签名 + 公证 + DMG)

先建一次 notarytool 的凭据(密码不进命令行):

```sh
xcrun notarytool store-credentials machands-notary \
  --apple-id you@example.com --team-id TEAMID
```

然后:

```sh
./scripts/release.sh \
  --sign "Developer ID Application: 你的名字 (TEAMID)" \
  --keychain-profile machands-notary \
  --version 0.1.0
```

它会:universal 构建 → Developer ID 签名(hardened runtime + entitlements)→
打 DMG → 提交公证并等结果 → 给 .app 和 DMG 都钉上票据 → 用 `spctl` 复核一遍
Gatekeeper 到底放不放行。每一步都会打印它在干什么;失败会给一句人话的下一步。

内部测试想跳过公证:加 `--skip-notarize`(那个 DMG 在别人机器上会被拦)。

## 常见的坑

| 现象 | 原因 / 怎么办 |
|---|---|
| `no such module 'MacHandsCore'` | 在 `macapp/` 目录里跑,不是仓库根目录 |
| `swift build` 说找不到 CryptoKit | 命令行工具太旧,`xcode-select --install` 更新 |
| 菜单栏没出现手 | 已经在跑了(它没有 Dock 图标);`pkill -f MacHands.app` 再开 |
| 「开机自动启动」是灰的 | 在跑 `.build` 里的裸二进制,不是 .app |
| 截屏返回 `EIO` | 屏幕录制没授权。系统设置 → 隐私与安全性 → 屏幕录制,勾上 MacHands |
| codesign 报 `resource fork ... not allowed` | `xattr -cr dist/MacHands.app` 再签 |
| 公证被拒 | `xcrun notarytool log <id> --keychain-profile machands-notary` 看原因 |
