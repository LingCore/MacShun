// SPDX-License-Identifier: MIT

import AppKit

@main
enum MacShunMain {
    @MainActor
    static func main() {
        // 被自己启动来读 PDF、认图片文字的子进程：读完就退出，不启动界面（见 ContentExtractor）
        if let request = ContentExtractor.helperRequest(in: CommandLine.arguments) {
            // 主程序忽略了 SIGTERM（见 AppDelegate），子进程会继承；恢复默认，超时时才结束得了
            signal(SIGTERM, SIG_DFL)
            ContentExtractor.runHelper(kind: request.kind, path: request.path, ocr: request.ocr)
        }
        // 改名前（Win顺）留下的数据文件夹和开机自启。要在 AppDelegate 读它们之前做
        FormerName.moveDataFolder()
        if !SelfTest.isRequested && !GuideTest.isRequested { FormerName.refreshLoginItem() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
