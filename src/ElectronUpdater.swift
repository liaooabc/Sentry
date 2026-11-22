import Foundation

// MARK: - electron-updater（electron-builder 的更新器）

/// Electron 应用走的不是 Sparkle，是 electron-updater：包里自带一份
/// `Contents/Resources/app-update.yml`，写明「去哪拿更新」；真正的最新版本号
/// 在同一个目录下的 `latest-mac.yml` 里（顶层一行 `version:`）。
///
/// 为什么单独开一条通道：本机 19 个 Electron App 里 12 个带这份 yml，
/// 而它们**全都没有 SUFeedURL**（Sparkle 那套对它们无效），以前只能靠
/// Homebrew cask 兜底 —— cask 由社区维护，滞后几天就把「新版已发布」报成
/// 「已是最新」，装的是官网版还会被商店版本号带偏。
/// 接上这条通道等于每个 Electron App 自带一条官方更新源，且**零维护**：
/// 地址就在包内，用户升级 App 后自己就是最新的。
struct ElectronFeed: Hashable {
    /// 已按可行性排好序的候选地址（latest-mac.yml 在前，channel 专属兜底）。
    /// github 型留空，走 API。
    let candidates: [String]
    /// `provider: github` 的包（洛雪音乐、zyfun 这类）只给了 owner/repo，
    /// 版本号在 Releases 里，直接复用 GitHub 那条通道，不必下 yml。
    let githubRepo: String?

    /// 用来推「官网」和给缓存做 key
    var primary: String { candidates.first ?? (githubRepo.map { "https://github.com/\($0)" } ?? "") }
}

enum ElectronUpdater {
    /// app-update.yml 的两个可能位置：正常打包在 Resources 下；
    /// 没打成 asar 的开发版会多一层 `app/`。
    private static let configPaths = [
        "Contents/Resources/app-update.yml",
        "Contents/Resources/app/app-update.yml",
    ]

    // MARK: 从包内读配置

    static func feed(appPath: String) -> ElectronFeed? {
        for rel in configPaths {
            let path = appPath + "/" + rel
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let f = feed(config: text) { return f }
        }
        return nil
    }

    /// 解析 app-update.yml 并推导候选地址。拿不到可用地址就返回 nil ——
    /// 返回 nil 意味着「这个 App 没有可用的 electron 源」，上层安静地落到 cask 那层，
    /// 不要留一条每轮必然失败的通道。
    static func feed(config: String) -> ElectronFeed? {
        let y = flatYAML(config)
        let provider = (y["provider"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()

        if provider == "github" {
            guard let owner = y["owner"]?.trimmingCharacters(in: .whitespaces), !owner.isEmpty,
                  let repo = y["repo"]?.trimmingCharacters(in: .whitespaces), !repo.isEmpty
            else { return nil }
            return ElectronFeed(candidates: [], githubRepo: "\(owner)/\(repo)")
        }

        // custom：更新地址写死在宿主 App 的代码里，包内没有可用 url（Trae CN 就是这种），别猜
        guard provider != "custom" else { return nil }

        guard var base = y["url"]?.trimmingCharacters(in: .whitespaces), !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard let u = URL(string: base), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host != nil
        else { return nil }

        // 有些包把 url 填成占位域名（光鸭云盘：https://updates.invalid/pc）。
        // 打过去必然失败，每轮都白等一次超时 —— 直接当没有这个源。
        if let host = u.host?.lowercased(), host == "updates.invalid" || host.hasSuffix(".invalid") {
            return nil
        }

        let channel = (y["channel"] ?? "").trimmingCharacters(in: .whitespaces)
        // 顺序是 latest 优先、channel 专属兜底，不是反过来。
        // 原因：electron-builder 默认就发 latest-mac.yml，`channel` 只是给多通道用的标记。
        // Notion 写着 `channel: arm64`，但它根本没有 arm64-mac.yml —— 那个地址实测
        // 15 秒超时（CDN 不响应不存在的对象），先试它就白等一次超时，还拖慢整轮扫描。
        // 反过来的代价只有「多打一个 404」，几十毫秒。
        var names = ["latest-mac.yml"]
        if !channel.isEmpty, channel != "latest" {
            names.append("\(channel)-mac.yml")
        }
        return ElectronFeed(candidates: names.map { "\(base)/\($0)" }, githubRepo: nil)
    }

    /// 只取顶层 `key: value`。app-update.yml 是扁平的，为一个文件引入 YAML 库不划算；
    /// 缩进行（`files:` 数组、多行值）一律跳过，免得把子键当成顶层键。
    static func flatYAML(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first,
                  first != " ", first != "\t", first != "#", first != "-"
            else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // url 常被写成 'https://…' 或 "https://…"
            if value.count >= 2,
               (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    // MARK: 解析 latest-mac.yml

    struct Latest: Equatable {
        let version: String
        let releaseDate: Date?
        /// 首选安装包文件名（优先 .dmg），用来拼下载地址
        let fileName: String?
    }

    /// 从 latest-mac.yml 里抠版本号。yaml 长这样：
    /// ```
    /// version: 1.129.0
    /// files:
    ///   - url: Canva可画-1.129.0-cn-universal-mac.zip
    ///   - url: Canva可画-1.129.0-cn-universal.dmg
    /// releaseDate: '2026-11-19T08:12:03.412Z'
    /// ```
    ///
    /// 只认**顶格**的 `version:`。缩进里不会有 version 键，但万一哪天对方改了结构，
    /// 顶格判断能挡住把 `files[].version` 之类的东西误当版本号。
    /// 拿不到版本号就返回 nil —— 幕布那个地址回的是 200 + 404 网页，靠这条兜住。
    static func parse(latestMacYML text: String) -> Latest? {
        var version: String?
        var releaseDate: Date?
        var preferred: String?
        var anyFile: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indented = raw.first == " " || raw.first == "\t"

            if !indented {
                if trimmed.hasPrefix("version:") {
                    version = cleanValue(String(trimmed.dropFirst("version:".count)))
                } else if trimmed.hasPrefix("releaseDate:") {
                    releaseDate = parseDate(cleanValue(String(trimmed.dropFirst("releaseDate:".count))))
                } else if trimmed.hasPrefix("path:"), anyFile == nil {
                    anyFile = cleanValue(String(trimmed.dropFirst("path:".count)))
                }
                continue
            }

            // files 数组里的 `- url: xxx`（也可能写成 `url: xxx`）
            guard anyFile == nil || preferred == nil else { continue }
            var candidate: String?
            if trimmed.hasPrefix("- url:") {
                candidate = cleanValue(String(trimmed.dropFirst("- url:".count)))
            } else if trimmed.hasPrefix("- path:") {
                candidate = cleanValue(String(trimmed.dropFirst("- path:".count)))
            }
            if let c = candidate, !c.isEmpty {
                if anyFile == nil { anyFile = c }
                if preferred == nil, c.lowercased().hasSuffix(".dmg") { preferred = c }
            }
        }

        guard let v = version, !v.isEmpty else { return nil }
        return Latest(version: v, releaseDate: releaseDate, fileName: preferred ?? anyFile)
    }

    private static func cleanValue(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2,
           (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// releaseDate 是 ISO8601，带毫秒（2026-11-19T08:12:03.412Z），
    /// 也见过不带毫秒的，两种都试。
    private static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return b.date(from: s)
    }
}
