import Foundation

/// 版本号比较：把字符串切成「数字段」和「字母段」逐段比。
/// 1.5.0 < 1.5.1、1.10 > 1.9、4.1.15 == 4.1.15
enum Ver {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = tokens(a)
        let pb = tokens(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let ta = i < pa.count ? pa[i] : .num(0)
            let tb = i < pb.count ? pb[i] : .num(0)
            let r = cmp(ta, tb)
            if r != .orderedSame { return r }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private enum Tok {
        case num(Int)
        case txt(String)
    }

    private static func tokens(_ s: String) -> [Tok] {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        var out: [Tok] = []
        var cur = ""
        var curIsDigit: Bool? = nil

        func flush() {
            guard !cur.isEmpty else { return }
            out.append((curIsDigit ?? false) ? .num(Int(cur) ?? 0) : .txt(cur.lowercased()))
            cur = ""
            curIsDigit = nil
        }

        for ch in cleaned {
            // 分隔符（. - _ 空格）只起断开作用，不进队列
            guard ch.isLetter || ch.isNumber else {
                flush()
                continue
            }
            let isDigit = ch.isNumber
            if let d = curIsDigit, d != isDigit { flush() }
            curIsDigit = isDigit
            cur.append(ch)
        }
        flush()
        return out
    }

    private static func cmp(_ a: Tok, _ b: Tok) -> ComparisonResult {
        switch (a, b) {
        case let (.num(x), .num(y)):
            if x == y { return .orderedSame }
            return x < y ? .orderedAscending : .orderedDescending
        case let (.txt(x), .txt(y)):
            if x == y { return .orderedSame }
            // 带后缀的（beta/rc）比不带后缀的旧
            if x.isEmpty { return .orderedDescending }
            if y.isEmpty { return .orderedAscending }
            return x < y ? .orderedAscending : .orderedDescending
        case (.txt, .num):
            return .orderedAscending
        case (.num, .txt):
            return .orderedDescending
        }
    }
}

/// 系统版本是否满足某个 minimumSystemVersion 要求
func systemSatisfies(_ minimum: String?, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) -> Bool {
    guard let minimum, !minimum.isEmpty else { return true }
    let os = osVersion.replacingOccurrences(of: "Version ", with: "")
        .components(separatedBy: " ").first ?? osVersion
    let trimmed = os.components(separatedBy: "(").first ?? os
    return Ver.compare(trimmed, minimum) != .orderedAscending
}

/// 更新源里那个「新版本」其实只是本机已经装着的构建号 —— 不是新版本。
///
/// 实测依据（这台机器上的 Microsoft Office）：
/// - CFBundleShortVersionString = 16.114.1（营销版本号）
/// - CFBundleVersion            = 16.114.26102031（构建号，日期编码）
/// - Homebrew cask 的 version   = 16.114.26102031
/// 只比营销版本号的话，Word / Excel / PowerPoint / OneNote / Outlook 会永远挂着假更新；
/// Outlook 更离谱：cask 记的 16.114.26101123 比本机装的 16.114.26102031 还旧，提示用户「升级」到旧包。
func latestIsInstalledBuild(_ latest: String, current: String, build: String?) -> Bool {
    guard let build, !build.isEmpty else { return false }

    // 1) 源里直接给的就是构建号
    if Ver.compare(latest, build) == .orderedSame { return true }

    let l = numericTokens(latest)
    let b = numericTokens(build)
    guard !l.isEmpty, !b.isEmpty else { return false }

    // 2) 源里只写到营销版本号，本机构建号是「它 + 一段长构建后缀」：
    //    16.114 + 26102031 —— 说明本机已经是那次发版之后编的包。
    if b.count > l.count, Array(b.prefix(l.count)) == l,
       b.dropFirst(l.count).allSatisfy({ $0.count >= 6 }) {
        return true
    }

    // 3) 两边都带长构建后缀且主版本段一致：比数字，build 不小就是同一个/更新的包。
    //    长后缀（>=6 位）是关键：避免把 1.14.4 → 1.14.5 这种正常补丁版误判成构建号。
    if l.count >= 3, b.count >= 3, Array(l.prefix(2)) == Array(b.prefix(2)),
       let lt = l.last, let bt = b.last, lt.count >= 6, bt.count >= 6 {
        return Ver.compare(latest, build) != .orderedDescending
    }

    return false
}

/// 把版本号尾巴上括起来的构建号拆出去：`1.58.0 (91297)` → (`1.58.0`, `91297`)。
///
/// 实测（Dia）：appcast 的 `shortVersionString` 写的是 `1.58.0 (91297)`，
/// 本机 `CFBundleShortVersionString` 是 `1.58.0`。整串拿去比就成了
/// 「1.58.0 (91297) 比 1.58.0 新」，装到最新了还天天挂着一个「可更新」。
/// 括号里那串只是构建号（跟 `CFBundleVersion` 一致），不影响版本号高低。
///
/// 只认「括号里全是数字或点」的写法，别把 `2.0 (Beta)`、`1.0 (Universal)` 这种真标签吃掉。
func splitTrailingBuild(_ raw: String) -> (version: String, build: String?) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = s.last, last == ")" || last == "）" else { return (s, nil) }
    guard let open = s.lastIndex(where: { $0 == "(" || $0 == "（" }) else { return (s, nil) }
    let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        .trimmingCharacters(in: .whitespaces)
    let head = String(s[s.startIndex..<open]).trimmingCharacters(in: .whitespaces)
    guard !head.isEmpty, !inner.isEmpty,
          inner.allSatisfy({ $0.isNumber || $0 == "." }),
          head.contains(where: { $0.isNumber }) else { return (s, nil) }
    return (head, inner)
}

/// 更新源给的构建号跟本机的一模一样 → 装的就是这个包（Dia 的 `sparkle:version` 91297）。
func sameBuild(_ source: String?, _ installed: String?) -> Bool {
    guard let a = source?.trimmingCharacters(in: .whitespaces), !a.isEmpty,
          let b = installed?.trimmingCharacters(in: .whitespaces), !b.isEmpty else { return false }
    return Ver.compare(a, b) == .orderedSame
}

private func numericTokens(_ s: String) -> [String] {
    s.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
}
