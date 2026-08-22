// swift-tools-version: 6.0
//
// CaptureKit — 采集核心（纯逻辑层）
//
// 设计依据：docs/superpowers/specs/2026-08-09-rune-m1-design.md §3
// 本包只包含不依赖 UI / 屏幕权限的纯逻辑（状态机、坐标换算、数据模型），
// 可在无 Xcode 环境下用 `swift test` 独立验证；
// ScreenCaptureKit 的具体采集引擎（ScreenTree/TCCSupport）在 M1 真机阶段并入；
// CaptureEngine / StillCapture 已以可替换门面形式定义，保持本包可独立测试。
//
// 测试框架：Swift Testing（Swift 6 工具链内置），
// 不依赖 XCTest —— Command Line Tools 环境无 XCTest，须可独立运行（M1 设计文档 §8）。

import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [
        .macOS(.v14)   // 对齐 BetterShot 最低系统版本
    ],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "CaptureKitSCK", targets: ["CaptureKitSCK"])
    ],
    targets: [
        .target(name: "CaptureKit"),
        // SCK 单帧截图引擎单独成 target：把 ScreenCaptureKit 依赖隔离在此处，
        // 使纯逻辑的 CaptureKit 仍可在无屏幕权限环境下用 `swift test` 独立验证。
        .target(
            name: "CaptureKitSCK",
            dependencies: ["CaptureKit"]
        ),
        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit"]
        )
    ]
)
