// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 界面文字。源文字是简体中文，同时就是查表用的键；英文译文在 Resources/en.lproj。
/// 带数字、名字的句子用格式串：`L("%ld 条", count)`，英文的单复数写在 Localizable.stringsdict 里。
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.uiLocale, arguments: args)
}

/// 界面语言：跟随系统，或者固定成中文、英文。改了要重启 Mac顺 才生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    /// 选项上的名字。语言名用它自己的文字写，哪种界面下都认得出来
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// 只看本程序自己的设置，不看系统全局的语言列表
    static var current: AppLanguage {
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        return own?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// 界面实际在用的语言（数字、日期也按它来写）
    static var uiLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
    }

    static var isChinese: Bool { uiLocale.identifier.hasPrefix("zh") }
}
