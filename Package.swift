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
        .executable(name: "mtk-probe", targets: ["mtk-probe"]),
        .executable(name: "mtk-server", targets: ["mtk-server"]),
        .executable(name: "mtk-viewer", targets: ["mtk-viewer"]),
    ],
    targets: [
        .target(name: "MultiTouchKit"),
        // 只放 C 標頭（multitouchkit.h），讓 Swift 實作與外部使用者共用同一份 ABI 定義
        .target(name: "CMultiTouchKit"),
        .target(name: "MultiTouchKitC", dependencies: ["MultiTouchKit", "CMultiTouchKit"]),
        .executableTarget(name: "mtk-probe", dependencies: ["MultiTouchKit"]),
        .executableTarget(name: "mtk-server", dependencies: ["MultiTouchKit"]),
        .executableTarget(name: "mtk-viewer", dependencies: ["MultiTouchKit"]),
        .testTarget(name: "MultiTouchKitTests", dependencies: ["MultiTouchKit"]),
    ]
)
