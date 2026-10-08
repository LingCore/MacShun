// SPDX-License-Identifier: MIT

import os

/// 日志。用“控制台”应用按子系统 io.github.lingcore.winshun 过滤查看。
enum Log {
    private static let subsystem = "io.github.lingcore.winshun"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let keyboard = Logger(subsystem: subsystem, category: "keyboard")
    static let mouse = Logger(subsystem: subsystem, category: "mouse")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
}
