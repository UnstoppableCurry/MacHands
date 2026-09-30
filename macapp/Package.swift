// swift-tools-version:5.9
import PackageDescription

// MacHands — free App Store edition (app.machands.MacHands.store).
// Separate product from the MIT agent bridge on master. Do not merge back.
//
// 分成两个 target:
//   MacHandsCore  纯 Foundation/CryptoKit/Security,不碰 AppKit —— 协议层与加密层,
//                 `swift test` 直接 import 它,不需要窗口服务器。
//   MacHands      AppKit 可执行程序(main.swift 里是顶层代码,SwiftPM 要求文件名就叫 main.swift)。
let package = Package(
    name: "MacHands",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacHands", targets: ["MacHands"]),
        .library(name: "MacHandsCore", targets: ["MacHandsCore"])
    ],
    targets: [
        .target(name: "MacHandsCore"),
        .executableTarget(name: "MacHands", dependencies: ["MacHandsCore"]),
        .testTarget(name: "MacHandsTests", dependencies: ["MacHandsCore"])
    ]
)
