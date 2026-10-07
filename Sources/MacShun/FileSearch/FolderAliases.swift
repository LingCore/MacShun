// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension FileMatcher {
    /// 文件夹在访达里显示的名字（“桌面”）和 Windows 上的叫法（“文档”“视频”）→ 真正的名字（比较用的形式）。
    static let folderAliases: [String: String] = {
        var map = [
            "桌面": "desktop", "文稿": "documents", "文档": "documents", "我的文档": "documents", "my documents": "documents",
            "下载": "downloads", "图片": "pictures", "影片": "movies", "视频": "movies", "videos": "movies",
            "音乐": "music", "公共": "public", "资源库": "library", "应用程序": "applications", "用户": "users",
        ]
        // 系统语言不是中文时，访达里显示的是那种语言的名字
        let home = NSHomeDirectory()
        let folders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Library"].map { home + "/" + $0 }
            + ["/Applications", "/Users"]
        for path in folders {
            let shown = FolderEntries.matchForm(FileManager.default.displayName(atPath: path), isASCII: false)
            let real = (path as NSString).lastPathComponent.lowercased()
            if shown != real { map[shown] = real }
        }
        return map
    }()
}
