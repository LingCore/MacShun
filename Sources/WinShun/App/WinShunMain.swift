// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@main
enum WinShunMain {
    @MainActor
    static func main() {
        // 被自己启动来读 PDF 的子进程：读完就退出，不启动界面（见 ContentExtractor）
        if let path = ContentExtractor.pdfHelperPath(in: CommandLine.arguments) {
            ContentExtractor.runPDFHelper(path: path)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
