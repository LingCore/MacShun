// swift-tools-version:6.0
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "MacShun",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacShun",
            path: "Sources/MacShun",
            exclude: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "MacShunTests",
            dependencies: ["MacShun"],
            path: "Tests/MacShunTests"
        ),
    ],
    // 事件拦截在独立线程上运行，和界面线程共享状态时用锁保护；
    // 暂时使用 Swift 5 语言模式，避免严格并发检查对 AppKit 回调代码的大量误报。
    swiftLanguageModes: [.v5]
)
