// SPDX-License-Identifier: MIT

import Foundation

/// 汉字转拼音，用于剪贴板历史的拼音搜索（C2）。
///
/// 用系统自带的 CFStringTransform 逐字转换。系统按字取最常见的读音，多音字常常转错，
/// 所以另外维护两张纠正表：单字的默认读音，和词语里的读音。
enum Pinyin {
    /// 系统默认读音不是最常用读音的字。
    static let charOverrides: [Character: String] = [
        "地": "di",     // 系统给 de，但“地方、地址、地图”更常见
        "长": "chang",  // 系统给 zhang，但“长度、很长、长期”更常见
    ]

    /// 词语里的读音。键是词语，值是逐字的拼音。
    static let phraseOverrides: [String: [String]] = [
        // 行 hang
        "银行": ["yin", "hang"], "行业": ["hang", "ye"], "行长": ["hang", "zhang"],
        "行情": ["hang", "qing"], "排行": ["pai", "hang"], "行列": ["hang", "lie"],
        "内行": ["nei", "hang"], "外行": ["wai", "hang"], "行家": ["hang", "jia"],
        "央行": ["yang", "hang"], "招行": ["zhao", "hang"], "建行": ["jian", "hang"],
        "工行": ["gong", "hang"], "农行": ["nong", "hang"], "商行": ["shang", "hang"],
        // 长 zhang
        "校长": ["xiao", "zhang"], "省长": ["sheng", "zhang"], "市长": ["shi", "zhang"],
        "县长": ["xian", "zhang"], "部长": ["bu", "zhang"], "院长": ["yuan", "zhang"],
        "组长": ["zu", "zhang"], "班长": ["ban", "zhang"], "家长": ["jia", "zhang"],
        "处长": ["chu", "zhang"], "局长": ["ju", "zhang"], "科长": ["ke", "zhang"],
        "队长": ["dui", "zhang"], "社长": ["she", "zhang"], "董事长": ["dong", "shi", "zhang"],
        "长大": ["zhang", "da"], "成长": ["cheng", "zhang"], "增长": ["zeng", "zhang"],
        "生长": ["sheng", "zhang"], "长辈": ["zhang", "bei"],
        // 重 chong
        "重新": ["chong", "xin"], "重复": ["chong", "fu"], "重庆": ["chong", "qing"],
        "重启": ["chong", "qi"], "重置": ["chong", "zhi"], "重做": ["chong", "zuo"],
        "重来": ["chong", "lai"], "重叠": ["chong", "die"], "重建": ["chong", "jian"],
        "重名": ["chong", "ming"], "重试": ["chong", "shi"], "重装": ["chong", "zhuang"],
        "重写": ["chong", "xie"], "重命名": ["chong", "ming", "ming"], "重播": ["chong", "bo"],
        "重组": ["chong", "zu"], "重逢": ["chong", "feng"], "重阳": ["chong", "yang"],
        "重连": ["chong", "lian"], "重发": ["chong", "fa"], "重定向": ["chong", "ding", "xiang"],
        // 乐 yue
        "音乐": ["yin", "yue"], "乐器": ["yue", "qi"], "乐队": ["yue", "dui"],
        "乐团": ["yue", "tuan"], "乐曲": ["yue", "qu"], "乐谱": ["yue", "pu"],
        "声乐": ["sheng", "yue"], "器乐": ["qi", "yue"], "乐清": ["yue", "qing"],
        // 都 du
        "首都": ["shou", "du"], "成都": ["cheng", "du"], "都市": ["du", "shi"],
        "京都": ["jing", "du"], "古都": ["gu", "du"], "都城": ["du", "cheng"],
        // 其他常见多音字
        "会计": ["kuai", "ji"],
        "了解": ["liao", "jie"], "了不起": ["liao", "bu", "qi"],
        "着急": ["zhao", "ji"], "睡着": ["shui", "zhao"], "着火": ["zhao", "huo"],
        "着凉": ["zhao", "liang"], "着迷": ["zhao", "mi"],
        "着装": ["zhuo", "zhuang"], "着手": ["zhuo", "shou"], "着陆": ["zhuo", "lu"],
        "着重": ["zhuo", "zhong"],
        "目的": ["mu", "di"], "的确": ["di", "que"], "的士": ["di", "shi"],
        "便宜": ["pian", "yi"],
        "弹琴": ["tan", "qin"], "弹性": ["tan", "xing"], "弹出": ["tan", "chu"],
        "弹窗": ["tan", "chuang"], "弹奏": ["tan", "zou"],
        "投降": ["tou", "xiang"],
        "人参": ["ren", "shen"], "海参": ["hai", "shen"],
        "率领": ["shuai", "ling"], "率先": ["shuai", "xian"], "坦率": ["tan", "shuai"],
        "直率": ["zhi", "shuai"], "草率": ["cao", "shuai"],
        "空调": ["kong", "tiao"], "调整": ["tiao", "zheng"], "调节": ["tiao", "jie"],
        "调试": ["tiao", "shi"], "协调": ["xie", "tiao"], "调和": ["tiao", "he"],
        "调皮": ["tiao", "pi"], "调解": ["tiao", "jie"], "调料": ["tiao", "liao"],
        "调剂": ["tiao", "ji"], "微调": ["wei", "tiao"],
        "出差": ["chu", "chai"], "参差": ["cen", "ci"],
        "厦门": ["xia", "men"],
        "薄荷": ["bo", "he"], "薄弱": ["bo", "ruo"], "单薄": ["dan", "bo"], "微薄": ["wei", "bo"],
        "传记": ["zhuan", "ji"], "自传": ["zi", "zhuan"],
        "还钱": ["huan", "qian"], "归还": ["gui", "huan"], "还款": ["huan", "kuan"],
        "退还": ["tui", "huan"], "偿还": ["chang", "huan"], "还原": ["huan", "yuan"],
        "给予": ["ji", "yu"], "供给": ["gong", "ji"],
        "角色": ["jue", "se"],
        "西藏": ["xi", "zang"], "宝藏": ["bao", "zang"],
        "校验": ["jiao", "yan"], "校对": ["jiao", "dui"], "校准": ["jiao", "zhun"],
        "校正": ["jiao", "zheng"],
        "模板": ["mu", "ban"], "模样": ["mu", "yang"], "模具": ["mu", "ju"],
        "蚌埠": ["beng", "bu"], "六安": ["lu", "an"],
        "反省": ["fan", "xing"],
    ]

    /// 按词语第一个字分组，查找更快。
    private static let phrasesByFirstChar: [Character: [(chars: [Character], syllables: [String])]] = {
        var map: [Character: [(chars: [Character], syllables: [String])]] = [:]
        for (phrase, syllables) in phraseOverrides {
            let chars = Array(phrase)
            guard chars.count == syllables.count, let first = chars.first else { continue }
            map[first, default: []].append((chars, syllables))
        }
        // 长的词优先匹配。
        for key in map.keys { map[key]?.sort { $0.chars.count > $1.chars.count } }
        return map
    }()

    private static let cache = Locked<[Character: String]>([:])

    static func isHan(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    /// 一个汉字的拼音，不带声调，小写。ü 写成 v（和输入法的习惯一致）。
    static func syllable(for ch: Character) -> String {
        if let override = charOverrides[ch] { return override }
        if let cached = cache.get()[ch] { return cached }
        let s = NSMutableString(string: String(ch))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        var latin = (s as String).lowercased()
        // 逐个 Unicode 码位比较：默认的比较会把 “uō” 当成 “ǖ”（都是 u 加符号），“缩 suō” 就成了 “sv”
        for u in ["ü", "ǖ", "ǘ", "ǚ", "ǜ"] {
            latin = latin.replacingOccurrences(of: u, with: "v", options: .literal)
        }
        let plain = NSMutableString(string: latin)
        CFStringTransform(plain, nil, kCFStringTransformStripDiacritics, false)
        let result = (plain as String).filter { $0.isLetter }
        cache.update { $0[ch] = result }
        return result
    }

    /// 文字逐字对应的拼音。汉字给出拼音，其他字符原样（小写）。
    static func syllables(of chars: [Character]) -> [String] {
        var result = chars.map { isHan($0) ? syllable(for: $0) : String($0).lowercased() }
        var i = 0
        while i < chars.count {
            var advanced = false
            if let candidates = phrasesByFirstChar[chars[i]] {
                for (phrase, syllables) in candidates where i + phrase.count <= chars.count {
                    if Array(chars[i..<(i + phrase.count)]) == phrase {
                        for (k, s) in syllables.enumerated() { result[i + k] = s }
                        i += phrase.count
                        advanced = true
                        break
                    }
                }
            }
            if !advanced { i += 1 }
        }
        return result
    }
}

/// 一段文字的搜索索引。
struct PinyinIndex {
    /// 原文（小写），用于直接包含匹配
    let lowercased: String
    /// 去掉空白后逐字的拼音（非汉字是字符本身）
    let syllables: [[Character]]

    /// 只索引前面这么多字，太长的文字后面部分只能按原文搜。
    static let maxIndexedCharacters = 1000

    init(text: String) {
        lowercased = text.lowercased()
        let chars = Array(text.prefix(Self.maxIndexedCharacters)).filter { !$0.isWhitespace }
        syllables = Pinyin.syllables(of: chars).map { Array($0) }
    }

    /// 搜索：原文包含、拼音全拼、首字母，以及全拼和首字母混合（例如 “jiantb” 搜到“剪贴板”）。
    func matches(_ query: String) -> Bool {
        let q = query.lowercased().filter { !$0.isWhitespace }
        if q.isEmpty { return true }
        if lowercased.contains(q) { return true }
        // 查询里有汉字等非 ASCII 字符时只按原文匹配。
        guard q.allSatisfy({ $0.isASCII }) else { return false }
        return Self.syllableMatch(Array(q), syllables)
    }

    /// 查询能否从某个字开始，连续地用每个字拼音的前缀（至少一个字母）拼出来。
    static func syllableMatch(_ q: [Character], _ s: [[Character]]) -> Bool {
        let n = q.count, m = s.count
        guard n > 0 else { return true }
        guard m > 0 else { return false }
        // can[qi][si]：q[qi...] 能否从第 si 个字开始拼出。从后往前算。
        var can = Array(repeating: Array(repeating: false, count: m + 1), count: n + 1)
        for si in 0...m { can[n][si] = true }
        for qi in stride(from: n - 1, through: 0, by: -1) {
            for si in stride(from: m - 1, through: 0, by: -1) {
                let syl = s[si]
                var k = 0
                while k < syl.count && qi + k < n && charMatches(q[qi + k], syl[k]) {
                    k += 1
                    if can[qi + k][si + 1] {
                        can[qi][si] = true
                        break
                    }
                }
            }
        }
        return (0..<m).contains { can[0][$0] }
    }

    /// 拼音里的 v（ü）也可以用 u 搜。
    private static func charMatches(_ q: Character, _ s: Character) -> Bool {
        q == s || (s == "v" && q == "u")
    }

    /// 和上面一样，只是查询和拼音都是字节：拼音逐字存成 ASCII，字之间用 0 隔开（文件名索引的存法）。
    /// 用临时缓冲区代替二维数组，搜几十万个文件名时少分配很多内存。
    static func syllableMatch(_ q: [UInt8], encoded s: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = q.count
        guard n > 0 else { return true }
        guard !s.isEmpty else { return false }
        var m = 1
        for byte in s where byte == 0 { m += 1 }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: m + 1) { starts in
            // 第 si 个字的拼音是 s[starts[si] ..< starts[si + 1] - 1]
            var k = 0
            starts[0] = 0
            for (i, byte) in s.enumerated() where byte == 0 {
                k += 1
                starts[k] = i + 1
            }
            starts[m] = s.count + 1
            let width = m + 1
            return withUnsafeTemporaryAllocation(of: Bool.self, capacity: (n + 1) * width) { can in
                can.initialize(repeating: false)
                for si in 0...m { can[n * width + si] = true }
                for qi in stride(from: n - 1, through: 0, by: -1) {
                    for si in stride(from: m - 1, through: 0, by: -1) {
                        let start = starts[si], end = starts[si + 1] - 1
                        var k = 0
                        while start + k < end && qi + k < n
                                && (q[qi + k] == s[start + k] || (s[start + k] == 0x76 && q[qi + k] == 0x75)) {
                            k += 1
                            if can[(qi + k) * width + si + 1] {
                                can[qi * width + si] = true
                                break
                            }
                        }
                    }
                }
                for si in 0 ..< m where can[si] { return true }
                return false
            }
        }
    }
}
