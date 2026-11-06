// swift-tools-version:5.10
import PackageDescription

// 唯一基准：docs/开发文档.md §5.2 模块划分 / §8 目录结构。
// 依赖方向单向：AppShell → 其余全部；各业务库只依赖 Contracts；
// OverlayKit 额外依赖 DesignSystem（浮条与弹窗要用主题 token）。
// 本文件由 T1 一次配好并冻结：后续任务不得修改 target 列表与依赖关系。
let package = Package(
    name: "TranslationReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TranslationReader", targets: ["TranslationReader"])
    ],
    targets: [
        // 共享契约：纯类型 + 协议，无逻辑、无 AppKit。
        .target(name: "Contracts"),

        .target(name: "DesignSystem", dependencies: ["Contracts"]),
        .target(name: "HotkeyKit", dependencies: ["Contracts"]),
        .target(name: "SelectionKit", dependencies: ["Contracts"]),
        .target(name: "OverlayKit", dependencies: ["Contracts", "DesignSystem"]),
        .target(name: "CaptureKitX", dependencies: ["Contracts"]),
        .target(name: "OCRVision", dependencies: ["Contracts"]),
        .target(name: "TranslateKit", dependencies: ["Contracts"]),
        .target(name: "SpeechKit", dependencies: ["Contracts"]),
        .target(name: "Store", dependencies: ["Contracts"]),

        // 可执行 target 的源码目录是 Sources/AppShell，模块名保持 TranslationReader。
        .executableTarget(
            name: "TranslationReader",
            dependencies: [
                "Contracts", "DesignSystem", "HotkeyKit", "SelectionKit", "OverlayKit",
                "CaptureKitX", "OCRVision", "TranslateKit", "SpeechKit", "Store",
            ],
            path: "Sources/AppShell"
        ),

        .testTarget(name: "TranslateKitTests", dependencies: ["TranslateKit", "Contracts"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "Contracts"]),
        // HotkeyKit / OverlayKit / DesignSystem：T2 的 HotkeyComboTests、OverlayLayoutTests 需要 import 它们。
        .testTarget(
            name: "SelectionKitTests",
            dependencies: ["SelectionKit", "Contracts", "HotkeyKit", "OverlayKit", "DesignSystem"]
        ),
        .testTarget(name: "OCRPostProcessTests", dependencies: ["OCRVision", "Contracts"]),
        .testTarget(name: "SpeechKitTests", dependencies: ["SpeechKit", "Contracts"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["Contracts", "DesignSystem", "OverlayKit", "HotkeyKit", "CaptureKitX"]
        ),
    ]
)
