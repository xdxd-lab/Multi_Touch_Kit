// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiTouchKit",
    platforms: [.macOS(.v13)],
    products: [
        // Swift 程式庫：給 Swift／SwiftUI／SpriteKit／Metal App 直接使用
        .library(name: "MultiTouchKit", targets: ["MultiTouchKit"]),
        // C ABI 動態程式庫：Unity 原生外掛、C/C++、Python ctypes、Godot、Rust 等使用
        .library(name: "MultiTouchKitC", type: .dynamic, targets: ["MultiTouchKitC"]),
        // 系統層手勢合成：把多點觸控轉成一般 macOS App 可用的點擊、捲動、縮放、旋轉、多指滑動
        .library(name: "MultiTouchKitGestures", targets: ["MultiTouchKitGestures"]),
        .executable(name: "mtk-probe", targets: ["mtk-probe"]),
        .executable(name: "mtk-server", targets: ["mtk-server"]),
        .executable(name: "mtk-viewer", targets: ["mtk-viewer"]),
    ],
    targets: [
        .target(name: "MultiTouchKit"),
        // 只放 C 標頭（multitouchkit.h），讓 Swift 實作與外部使用者共用同一份 ABI 定義
        .target(name: "CMultiTouchKit"),
        .target(name: "MultiTouchKitC", dependencies: ["MultiTouchKit", "CMultiTouchKit"]),
        .target(name: "MultiTouchKitGestures", dependencies: ["MultiTouchKit"]),
        .executableTarget(name: "mtk-probe", dependencies: ["MultiTouchKit"]),
        .executableTarget(name: "mtk-server", dependencies: ["MultiTouchKit", "MultiTouchKitGestures"]),
        .executableTarget(name: "mtk-viewer", dependencies: ["MultiTouchKit"]),
        .testTarget(name: "MultiTouchKitTests", dependencies: ["MultiTouchKit"]),
        .testTarget(name: "MultiTouchKitGesturesTests", dependencies: ["MultiTouchKitGestures", "MultiTouchKit"]),
        .testTarget(name: "MultiTouchKitCTests", dependencies: ["MultiTouchKitC", "CMultiTouchKit", "MultiTouchKit"]),
    ]
)
