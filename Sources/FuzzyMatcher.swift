import Foundation
import CoreFoundation

/// 启动台搜索：大小写不敏感 + 模糊匹配
///
/// 一个应用会被索引成多路检索键：
/// - 显示名（中文/英文，大小写与音标折叠）
/// - 拼音全拼：微信 → weixin
/// - 拼音 / 单词首字母：微信 → wx，Visual Studio Code → vsc
/// - 英文原名（.app 文件名）、bundle id、分类
///
/// 匹配按相关度打分，支持「多个关键词（空格分隔，全部命中才算）」与
/// 「跳字子序列」（cltr → Calculator、wch → WeChat）。
enum FuzzySearch {

    /// 单个应用的可检索键（生成一次、全局缓存，避免每次按键都做拼音转换）
    struct Keys {
        let name: String
        let compact: String
        let pinyins: [String]
        let initials: [String]
        let asciiName: String
        let bundleID: String
        let category: String
    }

    private static var cache: [String: Keys] = [:]
    private static let cacheLock = NSLock()

    /// CFStringTransform 对多音字会按上下文甚至按“最常见读音”消歧，
    /// 结果常常不对（地图→detu、银行→yinxing、音乐→yinle）。
    /// 为常见多音字补上备选读音，生成多个拼音变体，任一命中即可。
    /// 键：汉字；值：备选音节（不含声调，主读音由系统转换另外给出）。
    private static let polyphones: [Character: [String]] = [
        "地": ["di"], "重": ["chong"], "行": ["hang"], "乐": ["yue"],
        "长": ["chang"], "数": ["shuo"], "便": ["pian"], "系": ["ji"],
        "会": ["kuai"], "传": ["zhuan"], "查": ["zha"], "藏": ["zang"],
        "曾": ["zeng"], "屏": ["bing"], "血": ["xie"], "给": ["ji"],
        "匙": ["chi"], "钥": ["yue"], "薄": ["bo"], "着": ["zhao", "zhuo"],
        "差": ["chai", "ci"], "率": ["shuai", "lv"], "圈": ["juan"],
        "相": ["xiang"], "少": ["shao"], "干": ["gan"], "更": ["geng"],
        "还": ["hai"], "为": ["wei"], "了": ["liao"], "朝": ["chao"],
        "中": ["zhong"], "种": ["zhong"], "空": ["kong"], "假": ["jia"],
        "觉": ["jue"], "角": ["jue"], "省": ["xing"], "解": ["xie"],
        "载": ["zai"], "落": ["lao", "luo"], "露": ["lou"], "色": ["shai"],
        "削": ["xue"], "畜": ["chu"], "伺": ["ci"], "拓": ["ta"],
    ]

    /// 折叠大小写、音标、全半角，让 Café / cafe / CAFE 等价
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: .current).lowercased()
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { v in
            (0x3400...0x9FFF).contains(v.value) || (0xF900...0xFAFF).contains(v.value)
        }
    }

    /// 单个汉字 → 无声调拼音
    private static func syllable(_ c: Character) -> String {
        let m = NSMutableString(string: String(c)) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return fold(m as String).filter { $0.isLetter || $0.isNumber }
    }

    /// 把名字拆成「音节候选」序列：汉字给出主读音 + 多音备选，
    /// 连续的英文/数字作为一个整体保留。
    private static func tokens(_ name: String) -> [[String]] {
        var result: [[String]] = []
        var latin = ""
        func flushLatin() {
            if !latin.isEmpty {
                result.append([latin])
                latin = ""
            }
        }
        for ch in fold(name) {
            if ch.isLetter || ch.isNumber {
                if isCJK(ch) {
                    flushLatin()
                    var variants = [syllable(ch)]
                    for v in polyphones[ch] ?? [] where !variants.contains(v) {
                        variants.append(v)
                    }
                    result.append(variants.filter { !$0.isEmpty })
                } else {
                    latin.append(ch)
                }
            } else {
                flushLatin()   // 空格、连字符等作为分词边界
            }
        }
        flushLatin()
        return result.filter { !$0.isEmpty }
    }

    /// 生成拼音全拼与首字母的所有变体（笛卡尔积上限 24，避免组合爆炸）
    private static func pinyinKeys(_ name: String) -> (full: [String], initials: [String]) {
        let ts = tokens(name)
        var fulls: [String] = [""]
        var initials: [String] = [""]
        for group in ts {
            var nf: [String] = [], ni: [String] = []
            for f in fulls {
                for g in group where nf.count < 24 { nf.append(f + g) }
            }
            for i in initials {
                for g in group where ni.count < 24 {
                    ni.append(i + (g.first.map(String.init) ?? ""))
                }
            }
            fulls = nf
            initials = ni
        }
        return (Array(Set(fulls)).sorted { $0.count < $1.count },
                Array(Set(initials)).sorted { $0.count < $1.count })
    }

    static func keys(name: String, path: String?, bundleID: String?, category: String?) -> Keys {
        let ck = name + "|" + (path ?? "") + "|" + (bundleID ?? "") + "|" + (category ?? "")
        cacheLock.lock()
        if let hit = cache[ck] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let foldedName = fold(name)
        let py = pinyinKeys(name)
        let ascii = fold(((path as NSString?)?.lastPathComponent as NSString?)?
            .deletingPathExtension ?? "")
        let k = Keys(
            name: foldedName,
            compact: foldedName.filter { $0.isLetter || $0.isNumber },
            pinyins: py.full,
            initials: py.initials,
            asciiName: ascii,
            bundleID: fold(bundleID ?? ""),
            category: fold(category ?? "")
        )
        cacheLock.lock()
        cache[ck] = k
        cacheLock.unlock()
        return k
    }

    /// 贪心子序列：term 的字符按顺序出现即可（cltr → Calculator）
    private static func isSubsequence(_ term: String, in target: String) -> Bool {
        guard term.count >= 2, term.count <= target.count else { return false }
        var it = target.makeIterator()
        for ch in term {
            var found = false
            while let c = it.next() {
                if c == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    private static func best(_ term: String, in candidates: [String],
                             prefix: Int, equal: Int, contains: Int, subseq: Int) -> Int {
        var best = 0
        for c in candidates {
            if c == term { best = max(best, equal) }
            else if c.hasPrefix(term) { best = max(best, prefix) }
            else if c.contains(term) { best = max(best, contains) }
            else if isSubsequence(term, in: c) { best = max(best, subseq) }
        }
        return best
    }

    /// 单个关键词在某一路键上的最高相关度；0 = 不匹配
    private static func score(_ term: String, in k: Keys) -> Int {
        if k.name == term { return 1000 }
        if k.asciiName == term { return 980 }
        if k.name.hasPrefix(term) { return 900 }
        var s = best(term, in: k.pinyins, prefix: 880, equal: 885,
                     contains: 760, subseq: 380)
        s = max(s, best(term, in: k.initials, prefix: 740, equal: 870,
                        contains: 720, subseq: 360))
        if k.name.contains(term) { s = max(s, 800) }
        if k.compact.contains(term) { s = max(s, 780) }
        if k.asciiName.contains(term) { s = max(s, 700) }
        if k.bundleID.contains(term) { s = max(s, 600) }
        if k.category.contains(term) { s = max(s, 500) }
        if isSubsequence(term, in: k.compact) { s = max(s, 400) }
        if isSubsequence(term, in: k.asciiName) { s = max(s, 340) }
        return s
    }

    /// 整条查询的相关度；nil = 不匹配。多个关键词用空白分隔，需全部命中。
    static func relevance(query: String, name: String, path: String?,
                          bundleID: String?, category: String?) -> Int? {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
            .map { fold(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let k = keys(name: name, path: path, bundleID: bundleID, category: category)
        var total = 0
        for t in terms {
            let s = score(t, in: k)
            guard s > 0 else { return nil }
            total += s
        }
        return total + (terms.count > 1 ? 20 : 0)
    }

    /// 不带应用元数据时的纯名称查询（文件夹名等）
    static func relevance(query: String, name: String) -> Int? {
        relevance(query: query, name: name, path: nil, bundleID: nil, category: nil)
    }
}
