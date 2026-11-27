import Foundation

/// 1.5.0 / v4.13.3 / 2026.39 / "Version 4.13.3" 这种才算版本号，"Download" 这类标题不算。
/// 尾巴带括号构建号的也算（1.58.0 (91297)）：先拆掉括号再判，不然「有空格」这一条就把它挡了。
private func looksLikeVersion(_ s: String) -> Bool {
    var t = splitTrailingBuild(s).version.trimmingCharacters(in: .whitespaces)
    for prefix in ["Version ", "version ", "v"] where t.hasPrefix(prefix) {
        t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        break
    }
    guard t.count >= 1, t.count <= 24 else { return false }
    if t.contains(" ") { return false }
    guard let first = t.first, first.isNumber else { return false }
    return t.contains(where: { $0.isNumber })
}

/// 这个版本号是不是测试版：Beta / Alpha / RC / Preview / nightly …
/// 用途只有一个 —— 别拿测试版去提示更新（用户只要正式版，见 1.0.6 的需求）。
func isPrereleaseVersion(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    // 按「非字母数字」切词，避免 Marc / snapshot 这类词里凑出来的字母组合误判
    let words: Set<String> = ["beta", "alpha", "rc", "pre", "preview", "prerelease",
                              "nightly", "snapshot", "canary", "unstable", "test", "dev"]
    let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if tokens.contains(where: { words.contains($0) }) { return true }
    // 连写的：2.0.0-beta2 / 1.2.3rc1 / 3.0alpha
    let pattern = "(^|[^a-z])(alpha|beta|rc|dev|pre|preview|prerelease|nightly|snapshot|canary)[0-9]*([^a-z]|$)"
    if lower.range(of: pattern, options: .regularExpression) != nil { return true }
    return false
}

// MARK: - Sparkle appcast

final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var title: String?
        var shortVersion: String?
        var buildVersion: String?
        var minSystem: String?
        var link: String?
        var enclosure: String?
        var pubDate: String?
        var notes: String?
        var notesLink: String?
        /// <sparkle:channel>beta</sparkle:channel>：只有订阅了该通道的客户端才该收这条
        var channel: String?

        /// 源里写的那串原始版本号（还没拆掉括号里的构建号）
        private var rawMarketingVersion: String? {
            if let v = shortVersion?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
            if let t = title, looksLikeVersion(t) {
                // 去掉 "Version " 前缀再拿去比较
                var s = t.trimmingCharacters(in: .whitespaces)
                for p in ["Version ", "version "] where s.hasPrefix(p) {
                    s = String(s.dropFirst(p.count))
                    break
                }
                return s
            }
            return nil
        }

        /// 对外展示、用来比较的版本号。营销版本号优先，其次 title（老式 appcast 把版本写在 title 里），
        /// 最后才是构建号——构建号跟 CFBundleShortVersionString 不是一套编号，不能混比。
        ///
        /// 尾巴上的括号构建号要拆掉：Dia 的 `shortVersionString` 是 `1.58.0 (91297)`，
        /// 整串拿去比就会把「装到最新」判成「有新版」。
        var marketingVersion: String? {
            rawMarketingVersion.map { splitTrailingBuild($0).version }
        }

        /// 括号里那个构建号（Dia 的 91297），能跟本机 `CFBundleVersion` 直接对上
        var marketingBuild: String? {
            rawMarketingVersion.flatMap { splitTrailingBuild($0).build }
        }
    }

    /// 1.5.0 / v4.13.3 / 2026.39 这种才算版本号，"Download" 这类标题不算
    private(set) var items: [Item] = []
    private var current: Item?
    private var buffer = ""
    private var inItem = false

    func parse(_ data: Data) -> [Item] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let el = elementName.lowercased()
        if el == "item" {
            inItem = true
            current = Item()
        }
        if el == "enclosure", inItem {
            // Sparkle 1.5+ 常把版本写在 enclosure 属性上，而不是子元素里。
            // 属性名大小写、带不带 sparkle: 前缀都不统一，按「后缀匹配」取。
            if let url = Self.attr(attributeDict, names: ["url"]) {
                // <deltas> 里的增量包也挂在 enclosure 上，而且排在完整包后面。
                // 以前直接覆盖，Dia 就变成了「更新」点下去下一个 .delta（差分补丁，单独用装不上）。
                // 判据：带 sparkle:deltaFrom 的就是增量包，只当完整包缺失时的兜底。
                let isDelta = Self.attr(attributeDict,
                                        names: ["sparkle:deltasfrom", "deltasfrom",
                                                "sparkle:deltafrom", "deltafrom"]) != nil
                if !isDelta || current?.enclosure == nil {
                    current?.enclosure = url
                }
            }
            if current?.shortVersion == nil,
               let s = Self.attr(attributeDict, names: ["sparkle:shortversionstring", "shortversionstring"]) {
                current?.shortVersion = s
            }
            if current?.buildVersion == nil,
               let b = Self.attr(attributeDict, names: ["sparkle:version", "version"]) {
                current?.buildVersion = b
            }
            if current?.minSystem == nil,
               let m = Self.attr(attributeDict, names: ["sparkle:minimumsystemversion", "minimumsystemversion"]) {
                current?.minSystem = m
            }
        }
        if inItem { buffer = "" }
    }

    /// enclosure 属性：匹配完整名或「冒号后的本地名」，大小写不敏感。
    private static func attr(_ dict: [String: String], names: [String]) -> String? {
        let want = Set(names.map { $0.lowercased() })
        for (key, value) in dict {
            guard !value.isEmpty else { continue }
            let low = key.lowercased()
            let local = low.split(separator: ":").last.map(String.init) ?? low
            if want.contains(low) || want.contains(local) { return value }
        }
        return nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let el = elementName.lowercased()
        guard inItem else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "sparkle:shortversionstring":
            if !text.isEmpty { current?.shortVersion = text }
        case "title":
            if !text.isEmpty { current?.title = text }
        case "sparkle:version":
            if !text.isEmpty { current?.buildVersion = text }
        case "sparkle:minimumsystemversion":
            if !text.isEmpty { current?.minSystem = text }
        case "link":
            if !text.isEmpty { current?.link = text }
        case "pubdate":
            if !text.isEmpty { current?.pubDate = text }
        case "description":
            if current?.notes == nil, !text.isEmpty { current?.notes = text }
        case "sparkle:releasenoteslink":
            if !text.isEmpty { current?.notesLink = text }
        case "sparkle:channel":
            if !text.isEmpty { current?.channel = text }
        case "item":
            if let c = current { items.append(c) }
            current = nil
            inItem = false
        default:
            break
        }
        buffer = ""
    }
}

/// 更新说明常是 HTML，去掉标签、实体和多余空白，只留能读的字。
/// 上限放宽到 1600：列表里只显示一行，但左键点开要看全文。
func plainNotes(_ raw: String?, limit: Int = 1600) -> String? {
    guard var s = raw else { return nil }
    s = s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?s)<br\\s*/?>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                    "&quot;": "\"", "&#39;": "'", "&mdash;": "—", "&hellip;": "…"]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // 很多更新说明以·、•、- 开头，显示在行首很怪，去掉
    while let f = s.first, "·•-–—*>\u{2022}\u{00B7}\u{25CF}\u{3000} ".contains(f) {
        s.removeFirst()
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if s.count > limit { s = String(s.prefix(limit)) + "…" }
    return s
}

/// appcast 的 pubDate 是 RFC822 格式
func parseRFC822(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    if let d = f.date(from: s) { return d }
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: s)
}

func parseISO8601(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    return f.date(from: s)
}

// MARK: - 网络

/// Info.plist 里**没有** SUFeedURL、但确实用 Sparkle 的 App。
/// 这类把 feed 写在代码里（PastePal 的 SparkleService 就是 `feedURLStringForUpdater:` 返回的），
/// 包内翻不到地址，只能按 bundle id 钉一条官方 appcast。
/// 表要小：地址失效就当这个 App「无检测源」，不要为此加一堆兜底。
enum KnownAppcasts {
    static func feed(for app: InstalledApp) -> String? {
        feed(forBundleId: app.bundleId)
    }

    /// 传 bundle id 而不是整个 App：测试不用为了查一张表去拼 InstalledApp
    static func feed(forBundleId bundleId: String?) -> String? {
        switch bundleId {
        case "com.onmyway133.PastePal":
            // 作者自己发在 GitHub archives 仓库里的 appcast（标题 "PastePal Standalone"）。
            // 官网 pastepal.app / onmyway133.github.io 的 appcast 路径都已失效。
            return "https://raw.githubusercontent.com/onmyway133/archives/master/PastePal.xml"
        default:
            return nil
        }
    }
}

/// 商店里也有、但这台机器上装的是独立版的 App。
///
/// 这类 App 有两条互不相干的发行通道，版本号还常常不是一套，所以「用不用商店」要一个 App
/// 一个 App 地定：
/// - `.preferred`：商店版和独立版共用同一套版本号，商店就是最快最稳的那条路。
/// - `.fallback`：商店版通常落后于独立版，只在 appcast / cask 全都不通时兜一层，
///   总比显示「检测失败」强。
///
/// 表要小：只放查证过「商店记录确实存在、且是这个 App」的。
/// 反例：Telegram 的 `com.tdesktop.Telegram`（Telegram Desktop）压根不在 App Store，
/// cn / us / jp 三个区 lookup 都是 0 条；商店里的 Telegram 是另一款产品
/// （`ru.keepcoder.Telegram` 原生版，13.x），拿它的版本号去比 7.4.4 只会误报更新。
enum KnownAppStore {
    enum Mode {
        case preferred
        case fallback
    }

    static func mode(forBundleId bundleId: String?) -> Mode? {
        switch bundleId {
        case "com.ideasoncanvas.mindnode":
            // 商店记录是「一份通用 App」（features 带 iosUniversal），版本号就是 Mac 版的
            // 2026.x，跟独立版完全一致。发布说明页要 6~8 秒、还常被并发扫描挤成超时，
            // 商店这个请求几百毫秒就回。
            return .preferred
        case "com.onmyway133.PastePal":
            // 商店 2.17.0 / 独立版 2.22.4：商店版落后，抢第一顺位就等于放弃真正的版本号。
            // 但它的 appcast 挂在 raw.githubusercontent.com 上，国内时不时 TLS 失败，
            // 那时候商店记录至少能说清「你装的是最新独立版」。
            return .fallback
        default:
            return nil
        }
    }
}

/// 从更新源地址推「官网」：
/// - GitHub 托管的（raw.githubusercontent.com / github.com/owner/repo/...）→ 仓库页
/// - downloads./download./cdn. 开头的下载主机场 → 去掉那一段（downloads.skylum.com → skylum.com）
/// - 其余取站点根（mole.fit/appcast.xml → mole.fit）
func siteFromFeed(_ urlString: String?) -> String? {
    guard let s = urlString, let u = URL(string: s), let host = u.host?.lowercased() else { return nil }
    let parts = u.path.split(separator: "/").map(String.init)
    if host == "github.com" || host == "raw.githubusercontent.com" {
        if parts.count >= 2 { return "https://github.com/\(parts[0])/\(parts[1])" }
        return "https://github.com"
    }
    var bare = host
    for p in ["downloads.", "download.", "cdn.", "dl."] where bare.hasPrefix(p) {
        bare = String(bare.dropFirst(p.count))
        break
    }
    // 产品子域也收成主域：luminarneomac.skylum.com → skylum.com。
    // 但 github.io / netlify.app 这类托管后缀的主域没意义，别动。
    let labels = bare.split(separator: ".").map(String.init)
    let hosting = ["github.io", "netlify.app", "vercel.app", "pages.dev",
                   "gitlab.io", "fly.dev", "web.app", "firebaseapp.com"]
    if labels.count >= 3, !bare.hasPrefix("www.") {
        let base = labels.suffix(2).joined(separator: ".")
        if !hosting.contains(base) { bare = base }
    }
    // GitHub Pages 这类托管站，真正的站名在路径第一段：farzaa.github.io/clicky-releases
    if labels.count >= 3, hosting.contains(labels.suffix(2).joined(separator: ".")),
       let first = parts.first, !first.isEmpty {
        return "https://\(bare)/\(first)"
    }
    return "https://\(bare)"
}

enum Net {
    /// 单个请求的超时：8 秒会把「慢但活着」的源（CleanShot X 的 appcast 实测 10 秒）误判成失败
    static let requestTimeout: TimeInterval = 15

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // 死掉的源（停更的 appcast、国内连不上的接口）会一直占着并发槽位，
        // 所以超时不能给太宽裕；但 8 秒太紧了——CleanShot X 的 appcast 实测要 10 秒，
        // 会被误报成「更新源超时」。15 秒是两边都还过得去的值。
        c.timeoutIntervalForRequest = Net.requestTimeout
        c.timeoutIntervalForResource = Net.requestTimeout * 1.6
        // 默认每主机只 6 条连接，iTunes 查询动辄 30 个包，会被自己卡住
        c.httpMaximumConnectionsPerHost = 12
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: c)
    }()

    /// GitHub latest-release 的条件请求缓存。
    /// 带上 If-None-Match 后，release 没变就是 304，而 304 不计入 GitHub 的配额；
    /// 未登录只有 60 次/小时，不这么做 136 个 App 里 GitHub 源那部分很快就撞 403。
    private final class ETagCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (etag: String, data: Data)] = [:]

        func entry(_ key: String) -> (etag: String, data: Data)? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ key: String, etag: String, data: Data) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (etag, data)
        }

        func remove(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = nil
        }
    }

    private static let etags = ETagCache()

    /// raw.githubusercontent.com 在国内时通时不通，用 jsDelivr 做镜像兜底
    private static func jsdelivrMirror(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), url.host == "raw.githubusercontent.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let owner = parts[0], repo = parts[1], branch = parts[2]
        let rest = parts.dropFirst(3).joined(separator: "/")
        guard !rest.isEmpty else { return nil }
        return "https://cdn.jsdelivr.net/gh/\(owner)/\(repo)@\(branch)/\(rest)"
    }

    /// 抓 302 的落地地址（官网「下载」短链 → 真实安装包地址）。
    /// 刻意不跟下去：安装包几百兆，只要那串地址。ugapk 这类短链不支持 HEAD，
    /// 所以用 GET + 在重定向处掐断，一个字节的包都不下。
    private final class RedirectProbe: NSObject, URLSessionTaskDelegate {
        var target: URL?
        func urlSession(_ s: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            target = request.url
            completionHandler(nil)
        }
    }

    static func redirectTarget(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        let probe = RedirectProbe()
        let s = URLSession(configuration: session.configuration, delegate: probe, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.timeoutInterval = Net.requestTimeout
        _ = try? await s.data(for: req)      // 重定向被掐断会抛错，正常
        return probe.target
    }

    /// 更新源失败的原因。以前所有失败都压成一个 nil，上层只能笼统说「更新源没有响应」，
    /// 用户分不清是超时、404，还是源跳到了一张网页 —— Luminar Neo 就是第三种：
    /// 301 到一张追踪页，回了 200 但内容是 HTML，跟「网络不通」完全是两回事。
    enum SourceError: Error {
        case timeout
        case transport
        case status(Int)
        case empty
        case notAppcast
        case notUpdateManifest
        /// 清单拿到了、也能解析，但版本编号跟本机不是一套（抖音直播伴侣的框架版本号）。
        /// 这不算故障，上层要安静地当「没有检测源」，别报「地址已失效」误导人。
        case mismatchedVersion
        case noItems
        case incompatibleSystem

        var note: String {
            switch self {
            case .timeout: return "更新源超时（\(Int(Net.requestTimeout)) 秒没有响应）"
            case .transport: return "更新源连接失败（DNS 或 TLS 出错）"
            case .status(let code): return "更新源返回 HTTP \(code)"
            case .empty: return "更新源返回了空内容"
            case .notAppcast: return "更新源跳到的是网页，不是 appcast（源地址可能已失效）"
            case .notUpdateManifest: return "更新源跳到的是网页，不是 electron 更新清单（地址可能已失效）"
            case .mismatchedVersion: return "更新源里的版本号跟本机不是一套编号"
            case .noItems: return "更新源里没有可识别的版本条目"
            case .incompatibleSystem: return "更新源里的版本要求比本机系统更高，暂时装不了"
            }
        }
    }

    private static func fetch(_ urlString: String) async -> Result<String, SourceError> {
        guard let url = URL(string: urlString) else { return .failure(.transport) }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { return .failure(.transport) }
            guard (200..<300).contains(http.statusCode) else { return .failure(.status(http.statusCode)) }
            return .success(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        } catch let e as NSError {
            return .failure(e.domain == NSURLErrorDomain && e.code == NSURLErrorTimedOut ? .timeout : .transport)
        }
    }

    /// 注意：这里**故意不做失败重试**。以前失败会 sleep 0.5 秒再试一次，
    /// 等于把一个死掉的更新源（停更的 appcast、国内连不上的接口）的成本从 8 秒翻到 16 秒，
    /// 而并发槽位被它占着，整轮检查就被一两个死源拖到十几秒。
    /// 现在只保留 raw.githubusercontent.com → jsDelivr 的镜像兜底（那是「换条路能通」，
    /// 不是「同一条路再撞一次」）。
    static func text(_ urlString: String) async -> String? {
        if case .success(let s) = await textResult(urlString) { return s }
        return nil
    }

    /// 少数官网页面本身就慢（MindNode 发布说明页带压缩也有 39KB，实测 7 秒以上），
    /// 全局 15 秒在并发扫描时会把它挤成超时 —— 这种单独放宽，不牵动其它源。
    static func text(_ urlString: String, timeout: TimeInterval) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// 和 text 一样，但把失败原因带上去（只有 appcast 这条路要看原因）
    static func textResult(_ urlString: String) async -> Result<String, SourceError> {
        let first = await fetch(urlString)
        if case .failure = first, let alt = jsdelivrMirror(urlString) {
            return await fetch(alt)
        }
        return first
    }

    /// HTTP 状态码。GitHub 未认证时限流会返回 403 + X-RateLimit-Remaining: 0，
    /// 和「仓库不存在 / 网络不通」返回的 404 是完全不同的两回事，
    /// 混成一个 nil 的话上层只能笼统报「检测失败」，用户无从下手。
    struct HTTPError: Error {
        let status: Int
        /// 剩余配额（GitHub 的 X-RateLimit-Remaining），nil 表示该响应没带这个头
        let rateLimitRemaining: Int?
        var isRateLimited: Bool {
            if status == 429 { return true }
            if status == 403, let r = rateLimitRemaining, r <= 0 { return true }
            return false
        }
    }

    /// GitHub 专用：区分「限流」和「仓库没了」。
    /// 未认证配额只有 60 次/小时/IP（同一个 Wi-Fi 下几台 Mac 共用），撞墙时要说清原因。
    /// 所以优先走网页跳转（/releases/latest 302 → /releases/tag/vX.Y.Z），普通网页请求不占配额；
    /// 跳转不通才回退 API（带 ETag，没变就 304、不计配额）。
    static func githubLatestRelease(_ repo: String) async -> Result<[String: Any]?, HTTPError> {
        if let tag = await githubLatestTagViaRedirect(repo) {
            return .success(["tag_name": tag])
        }
        return await githubLatestReleaseViaAPI(repo)
    }

    /// 抠 302 的落地地址：/releases/latest → /releases/tag/vX.Y.Z，读 tag。
    /// 掐断重定向后 data(for:) 会抛错，所以目标地址由代理侧记，不走返回值。
    private static func githubLatestTagViaRedirect(_ repo: String) async -> String? {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else { return nil }
        let blocker = RedirectBlocker()
        // 复用 Net.session 的配置（自定义 UA、缓存策略），裸 CFNetwork UA 有被拒的可能
        let s = URLSession(configuration: session.configuration, delegate: blocker, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = Net.requestTimeout
        _ = try? await s.data(for: request)   // 重定向被掐断会抛错，正常
        guard let final = blocker.target?.absoluteString else { return nil }
        guard let tag = final.components(separatedBy: "/releases/tag/").last,
              !tag.isEmpty, tag != final else { return nil }
        return tag
    }

    /// 挡住重定向，只记落地地址（与 redirectTarget 的 RedirectProbe 同套路）
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        var target: URL?
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            target = request.url
            completionHandler(nil)
        }
    }

    private static func githubLatestReleaseViaAPI(_ repo: String) async -> Result<[String: Any]?, HTTPError> {
        let url = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let u = URL(string: url) else { return .success(nil) }
        var request = URLRequest(url: u)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let hit = etags.entry(url) {
            request.setValue(hit.etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return .success(nil) }
            if http.statusCode == 304, let hit = etags.entry(url) {
                return .success(try? JSONSerialization.jsonObject(with: hit.data) as? [String: Any])
            }
            guard (200..<300).contains(http.statusCode) else {
                // 403/429 说明配额已经用完，缓存留着也没用（ETag 也不会让 304 生效）
                etags.remove(url)
                let remain = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
                return .failure(HTTPError(status: http.statusCode, rateLimitRemaining: remain))
            }
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                etags.store(url, etag: etag, data: data)
            }
            return .success(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch {
            return .success(nil)
        }
    }

    static func json(_ urlString: String) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Homebrew Cask

/// Homebrew Cask 是社区维护的 Mac 软件版本库（7000+ 个 App，含大量没有 appcast 的商业软件）。
/// 设计取舍：18MB 的完整索引不下载 —— 随 App 带一张 120KB 的「App 名 → cask 名」表，
/// 运行时只按需拉单个 cask 的 1KB JSON，结果缓存 12 小时。这样内存和流量都可控。
enum Cask {
    struct Entry {
        let token: String
        let version: String
        let homepage: String?
    }

    private static let lock = NSLock()
    private static var store: [String: Cached]?
    private static var mapLoaded = false
    private static var nameMap: [String: String] = [:]
    private static var bundleMap: [String: String] = [:]

    private struct Cached: Codable {
        var version: String
        var homepage: String?
        var fetchedAt: Date
        var bundles: [String]?     // cask 里登记的 bundle id，用来复核同名不同版
    }

    private static var cacheURL: URL { SentrySupportDir.appendingPathComponent("cask-cache.json") }

    /// 名称表随包发布：{"apps": {"sketch.app": "sketch"}, "bundles": {"com.microsoft.Word": "microsoft-word"}}
    private static func loadMap() {
        // 12 路并发 Task 会同时进来：没这把锁就是两个线程同时写 Dictionary（会真崩）
        lock.lock(); defer { lock.unlock() }
        guard !mapLoaded else { return }
        mapLoaded = true
        guard let url = Bundle.main.url(forResource: "cask-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        nameMap = obj["apps"] as? [String: String] ?? [:]
        bundleMap = obj["bundles"] as? [String: String] ?? [:]
    }

    /// 一个 App 对应哪个 cask：先按 .app 文件名，再按 bundle id
    static func token(for app: InstalledApp) -> (token: String, exact: Bool)? {
        loadMap()
        // bundle id 最可靠（能排除同名不同 App），其次才按 .app 文件名
        if let bid = app.bundleId, let t = bundleMap[bid] { return (t, true) }
        let file = (app.path as NSString).lastPathComponent.lowercased()
        if let t = nameMap[file] { return (t, false) }
        return nil
    }

    /// cask 的 uninstall 段里写着「卸载时要退出的 bundle id」（如 notion.id），
    /// 拿它反查这到底是哪个 App。只看 uninstall：zap/trash 里混着路径，会误判。
    /// （不是 private：回归测试要直接调。）
    static func bundleIds(in obj: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] { d.values.forEach(walk) }
            else if let a = o as? [Any] { a.forEach(walk) }
            else if let str = o as? String {
                for part in str.split(whereSeparator: { " ,;".contains($0) }) {
                    let t = String(part)
                    let dots = t.filter { $0 == "." }.count
                    let clean = t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                    // dots >= 2 已经把「Notion.app」这种文件名挡在外面（它只有一个点），
                    // 所以不能再按 .app 结尾过滤：cn.trae.app 这种**真 bundle id 就以 .app 结尾**，
                    // 滤掉它，cask-map 里就永远缺这一条（Trae CN 当初就是这么漏的）。
                    if dots >= 2, clean, !t.hasSuffix(".plist") {
                        ids.insert(t)
                    }
                }
            }
        }
        for a in obj["artifacts"] as? [Any] ?? [] {
            if let d = a as? [String: Any], let u = d["uninstall"] { walk(u) }
        }
        return ids
    }

    private static func loadCache() -> [String: Cached] {
        lock.lock(); defer { lock.unlock() }
        if let store { return store }
        var loaded: [String: Cached] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Cached].self, from: data) {
            loaded = decoded
        }
        store = loaded
        return loaded
    }

    private static func saveCache(_ entry: Cached, token: String) {
        lock.lock(); defer { lock.unlock() }
        var current = store ?? [:]
        current[token] = entry
        // 只留最近 300 条，别让缓存文件无限长
        if current.count > 300 {
            let newest = current.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(300)
            current = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        store = current
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: cacheURL)
        }
    }

    /// 1.2.3,456 → 1.2.3；3.6.7-dbc92f97 → 3.6.7；2026.3.1 原样
    /// （不是 private：回归测试要直接调。）
    static func cleanVersion(_ raw: String) -> String? {
        var v = raw.split(separator: ",").first.map(String.init) ?? raw
        v = v.trimmingCharacters(in: .whitespaces)
        // 只在后缀是「构建号 / commit」这种形态时才截断。4.0.0-beta.1 这类是**预发布版本号**，
        // 截断会变成正式版 4.0.0：上层 isPrereleaseVersion 再也看不到 beta，
        // 于是把 beta 当成正式更新推给用户（仓库里 7813 个 cask 有 59 个是这种写法）。
        if !isPrereleaseVersion(v), let dash = v.firstIndex(of: "-"),
           v[..<dash].contains(where: { $0.isNumber }) {
            v = String(v[..<dash])
        }
        guard let first = v.first, first.isNumber else { return nil }
        return v
    }

    /// 单个 cask 的缓存时长。Homebrew 一天会更新几十次，12 小时太钝——
    /// 今天 Gemini / UU远程 就是因为缓存过期前拿到的是旧版本号，被当成「已是最新」。
    /// 2 小时够省流量（每个 App 一次 1KB 请求），点「扫描」还会强制绕过缓存。
    private static let cacheTTL: TimeInterval = 2 * 3600

    private static func fetch(_ token: String, force: Bool = false) async -> Cached? {
        if !force, let hit = loadCache()[token], Date().timeIntervalSince(hit.fetchedAt) < cacheTTL {
            return hit
        }
        guard let obj = await Net.json("https://formulae.brew.sh/api/cask/\(token).json") as? [String: Any],
              let raw = obj["version"] as? String,
              let version = cleanVersion(raw) else { return nil }
        let entry = Cached(version: version,
                           homepage: obj["homepage"] as? String,
                           fetchedAt: Date(),
                           bundles: Array(bundleIds(in: obj)))
        saveCache(entry, token: token)
        return entry
    }

    static func lookup(_ app: InstalledApp, force: Bool = false) async -> Entry? {
        guard let hit = token(for: app) else { return nil }
        guard let c = await fetch(hit.token, force: force) else { return nil }
        // 只按文件名对上的，再用 cask 登记的 bundle id 复核一次：
        // 本机装的是 Telegram Desktop（com.tdesktop.Telegram），cask 里是原生版（ru.keepcoder.Telegram），名字一样但不是同一个 App
        if !hit.exact, let ids = c.bundles, !ids.isEmpty, let bid = app.bundleId, !ids.contains(bid) {
            // 同一厂商前缀（com.topazlabs.*）算过关：这种 cask 是装 pkg 的，
            // uninstall 段里登记的是安装包 id（com.topazlabs.VStudioPackage），
            // 不是 App 的 bundle id（com.topazlabs.Topaz-Video）。
            let family = vendorPrefix(bid)
            if !ids.contains(where: { vendorPrefix($0) == family }) { return nil }
        }
        return Entry(token: hit.token, version: c.version, homepage: c.homepage)
    }

    /// 变成检测结果；本机比库里还新时给一句解释（内测版/官网还没同步）
    /// 16.114 对 16.114.26101123：多出来的那段是构建号，不是新版本
    static func isBuildOnlyBump(_ latest: String, over current: String) -> Bool {
        let l = latest.split(separator: ".").map(String.init)
        let c = current.split(separator: ".").map(String.init)
        guard l.count > c.count, Array(l.prefix(c.count)) == c else { return false }
        return l.dropFirst(c.count).allSatisfy { $0.count >= 6 && $0.allSatisfy(\.isNumber) }
    }

    /// bundle id 的厂商前缀：com.topazlabs.Topaz-Video → com.topazlabs
    /// （不是 private：回归测试要直接调。）
    static func vendorPrefix(_ bundleId: String) -> String {
        bundleId.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func verdict(_ app: InstalledApp, entry: Entry, allowBeta: Bool) -> Checker.Outcome {
        // 「只跟正式版比」是给装正式版的人用的。本机装的本身就是测试版（用户已经在尝鲜通道上），
        // 那跟测试版比才是有意义的，不然等于把他钉死在当前这个 RC 上。
        let compareBeta = allowBeta || isPrereleaseVersion(app.version)
        // 版本库里记的是测试版时不提示（有些 cask 会跟到 beta 上）
        if !compareBeta, isPrereleaseVersion(entry.version) {
            return Checker.Outcome(status: .upToDate, latest: app.version,
                                   url: entry.homepage ?? "https://formulae.brew.sh/cask/\(entry.token)",
                                   homepage: entry.homepage,
                                   note: "只跟正式版比：版本库里现在记的是测试版（\(entry.version)）",
                                   suppressedBeta: true)
        }
        // 版本库里记的是构建号（Office 的 cask version 就是 16.114.26102031）：
        // 本机装的就是这个包，别报更新。
        if latestIsInstalledBuild(entry.version, current: app.version, build: app.build) {
            return Checker.Outcome(status: .upToDate, latest: entry.version,
                                   url: entry.homepage ?? "https://formulae.brew.sh/cask/\(entry.token)",
                                   homepage: entry.homepage, note: nil)
        }
        if isBuildOnlyBump(entry.version, over: app.version) {
            return Checker.Outcome(status: .upToDate, latest: entry.version, url: entry.homepage, note: nil)
        }
        let newer = Ver.isNewer(entry.version, than: app.version)
        let note: String? = (!newer && Ver.isNewer(app.version, than: entry.version))
            ? "社区版本库记录的是 \(entry.version)，你装的更新（可能是内测版）"
            : nil
        return Checker.Outcome(status: newer ? .updateAvailable : .upToDate,
                               latest: entry.version,
                               url: entry.homepage ?? "https://formulae.brew.sh/cask/\(entry.token)",
                               homepage: entry.homepage,
                               note: note)
    }
}

// MARK: - 检测器

enum Checker {
    /// - Parameter previous: 上一轮的检测结果。官网只放安装包、不写版本号的 App
    ///   （扣子桌面端这种）要靠它比「官网的包是不是换了」
    /// - Parameter allowBeta: 用户打开了「接收测试版」时才为 true；默认只跟正式版比
    /// 检测一个 App。**顺序很重要**：从 Mac App Store 装的先问商店 —— 商店才是这个包的更新通道。
    /// 商店包和「官网直接下载版」是两条独立的通道，版本号常常压根不是一套
    /// （QQ 商店 7.0.2 / 官网 6.9.x；WPS 商店 12.1.29182 / 官网 12.1.x）：
    /// 拿官网或 appcast 的版本去跟商店包比，只会误报「有新版本」，点进去还得自己下载安装包。
    static func check(_ app: InstalledApp, previous: CheckResult? = nil,
                      allowBeta: Bool = false, forceCask: Bool = false) async -> CheckResult {
        guard app.isAppStore, let bid = app.bundleId else {
            return await checkOtherSources(app, previous: previous, allowBeta: allowBeta,
                                           forceCask: forceCask)
        }
        let now = Date()

        // 1. 商店：cn 和 us 并行查，**取两个里版本号更高的**。
        //    iTunes lookup 每个区走自己的 CDN 节点，发版后不同区刷新时间差可能超过 1 小时；
        //    之前串行查 cn 有结果就不查 us，经常正好撞上 cn 还缓存着旧数据、us 已经刷了的情况。
        async let cnOutcome = appStore(bundleId: bid, name: app.name, current: app.version, build: app.build,
                                       installedAt: app.installedAt, country: "cn",
                                       allowBeta: allowBeta)
        async let usOutcome = appStore(bundleId: bid, name: app.name, current: app.version, build: app.build,
                                       installedAt: app.installedAt, country: "us",
                                       allowBeta: allowBeta)
        let outcomes = [await cnOutcome, await usOutcome].compactMap { $0 }

        if let best = pickBestAppStoreOutcome(outcomes) {
            return CheckResult(bundleId: bid, status: best.status, latest: best.latest,
                               downloadURL: best.url, homepage: best.homepage, note: best.note,
                               source: "appstore", checkedAt: now,
                               releaseDate: best.releaseDate, notes: best.notes,
                               suppressedBeta: best.suppressedBeta ? true : nil)
        }

        // 2. MAS 版 App 但 iTunes lookup 也查不到（已下架、bundleId 对不上、网络故障）。
        //    关键：**MAS 版绝不能 fallback 到官网 / Sparkle / Cask 去查版本号**。
        //    商店包和官网版经常不是一套版本号（QQ 商店 7.0.2 vs 官网 6.9.x），
        //    拿官网的版本去跟商店包比只会误报更新，用户点进去还得自己重新下载。
        //    要么说「商店查不到」，要么说「检测失败」，就这两条路。
        let reason: String?
        if outcomes.isEmpty {
            // cn 和 us 两个都返回 nil：要么 iTunes lookup 真没这个 App（下架），要么网络全挂了
            reason = "从 App Store 装的，但商店查不到这个 App（可能已下架，或 bundleId 不匹配）"
        } else {
            reason = "从 App Store 装的，但商店接口返回异常"
        }
        return CheckResult(bundleId: bid, status: .unknown, latest: nil,
                           downloadURL: nil, note: reason, source: "manual",
                           checkedAt: now)
    }

    /// cn 和 us 两个 iTunes lookup 都返回了 Outcome 时，挑一个更可信的：
    /// - 两个版本号不一样 → 取版本号更高的（一个 CDN 刷新了、另一个还没）
    /// - 版本号一样 → 哪个是 cn 取哪个（国内用户更大概率从国区商店装）
    private static func pickBestAppStoreOutcome(_ outcomes: [Outcome]) -> Outcome? {
        guard !outcomes.isEmpty else { return nil }
        if outcomes.count == 1 { return outcomes[0] }
        // 两个都有版本号 → 取更新的；只有一个有版本号 → 取有的那个
        //（另一个可能是 iOS 主记录被判成「核对不了」，latest 为空）
        var best = outcomes[0]
        for o in outcomes.dropFirst() {
            if best.latest == nil, o.latest != nil { best = o; continue }
            if let bv = best.latest, let ov = o.latest, Ver.isNewer(ov, than: bv) {
                best = o
            }
        }
        return best
    }

    /// 商店之外的检测源：厂商规则 → Sparkle appcast → Homebrew Cask
    private static func checkOtherSources(_ app: InstalledApp, previous: CheckResult?,
                                          allowBeta: Bool, forceCask: Bool) async -> CheckResult {
        let bid = app.id
        let now = Date()

        func failed(_ note: String) -> CheckResult {
            CheckResult(bundleId: bid, status: .failed, latest: nil,
                        downloadURL: nil, note: note, source: "failed", checkedAt: now)
        }

        /// 商店兜底：只有 `KnownAppStore` 里登记过、且标了 `.fallback` 的才问。
        /// 放在每条链的末尾 —— 商店版一般落后于独立版，只是「别让结果变成无源/失败」的第五层。
        func storeFallback() async -> CheckResult? {
            guard KnownAppStore.mode(forBundleId: app.bundleId) == .fallback,
                  let o = await appStoreFallback(app, allowBeta: allowBeta) else { return nil }
            return result(app, o, source: "appstore", now: now)
        }

        // 0. 商店优先：商店版跟独立版共用同一套版本号的那几个（MindNode），
        //    问商店比爬官网发布页快一个数量级，也不用担心那页被并发挤成超时。
        if KnownAppStore.mode(forBundleId: app.bundleId) == .preferred,
           let o = await appStoreFallback(app, allowBeta: allowBeta) {
            return result(app, o, source: "appstore", now: now)
        }

        // 1. 厂商专用规则优先（微信这类没有 appcast 的常用软件）
        if let rule = Rules.match(app) {
            if let r = await rule.run(app, previous, allowBeta) {
                return CheckResult(bundleId: bid, status: r.status, latest: r.latest,
                                   downloadURL: r.url, homepage: r.homepage ?? r.url, note: r.note,
                                   source: "vendor",
                                   checkedAt: now, releaseDate: r.releaseDate, notes: r.notes,
                                   marker: r.marker, suppressedBeta: r.suppressedBeta ? true : nil)
            }
            // 规则命中但这次没抓到：说明是网络/页面变动问题，不是“没有检测源”
            if let r = await storeFallback() { return r }
            return failed("官网页面没抓到版本号")
        }

        // 2. Sparkle appcast：近 40 个 App 走这条路
        //    少数 App 的 feed 不是写在 Info.plist 里，而是写死在代码中（PastePal 的
        //    SparkleService），包内查不到 SUFeedURL —— 这种由 KnownAppcasts 按 bundle id 补一条。
        if let feed = app.sparkleFeed ?? KnownAppcasts.feed(for: app) {
            switch await sparkle(feed: feed, current: app.version, build: app.build,
                                 allowBeta: allowBeta) {
            case .success(let r):
                return CheckResult(bundleId: bid, status: r.status, latest: r.latest,
                                   downloadURL: r.url,
                                   homepage: r.homepage ?? siteFromFeed(feed),
                                   note: nil, source: "sparkle",
                                   checkedAt: now, releaseDate: r.releaseDate, notes: r.notes,
                                   suppressedBeta: r.suppressedBeta ? true : nil)
            case .failure(let why):
                // appcast 这次没抓到：先用社区版本库兜一层，再让商店兜一层，别急着报「检测失败」
                if let entry = await Cask.lookup(app, force: forceCask) {
                    return result(app, Cask.verdict(app, entry: entry, allowBeta: allowBeta), source: "cask", now: now)
                }
                if let r = await storeFallback() { return r }
                return failed(why.note)
            }
        }

        // 3. electron-updater：Electron 包没有 appcast，更新源在包内 app-update.yml。
        //    放在 cask 之前 —— 官方清单一定比社区维护的 cask 新。
        if let feed = app.electronFeed {
            switch await electron(app, feed: feed, allowBeta: allowBeta) {
            case .success(let r):
                return CheckResult(bundleId: bid, status: r.status, latest: r.latest,
                                   downloadURL: r.url, homepage: r.homepage ?? siteFromFeed(feed.primary),
                                   note: r.note, source: "electron",
                                   checkedAt: now, releaseDate: r.releaseDate, notes: r.notes,
                                   suppressedBeta: r.suppressedBeta ? true : nil)
            case .failure(let why):
                // 和 appcast 一样：源这次没抓到先让 cask 兜一层，别急着报失败
                if let entry = await Cask.lookup(app, force: forceCask) {
                    return result(app, Cask.verdict(app, entry: entry, allowBeta: allowBeta), source: "cask", now: now)
                }
                if let r = await storeFallback() { return r }
                // 编号体系对不上（抖音直播伴侣）不是故障，安静地记作「没有检测源」，
                // 否则用户会看到一条「地址可能已失效」，而实际上源是好的。
                if case .mismatchedVersion = why {
                    return CheckResult(bundleId: bid, status: .unknown, latest: nil,
                                       downloadURL: nil, note: nil, source: "manual", checkedAt: now)
                }
                return failed(why.note)
            }
        }

        // 4. Homebrew Cask：没有 appcast、不在商店、也没有厂商规则的，最后一层
        if let entry = await Cask.lookup(app, force: forceCask) {
            return result(app, Cask.verdict(app, entry: entry, allowBeta: allowBeta), source: "cask", now: now)
        }

        // 5. 商店兜底：一个源都没有的，最后问一次 App Store（只问登记过的几个）
        if let r = await storeFallback() { return r }

        return CheckResult(bundleId: bid, status: .unknown, latest: nil,
                           downloadURL: nil, note: nil, source: "manual", checkedAt: now)
    }

    /// Outcome → CheckResult（cask 这条路用，带来源标记）
    static func result(_ app: InstalledApp, _ o: Outcome, source: String, now: Date) -> CheckResult {
        CheckResult(bundleId: app.id, status: o.status, latest: o.latest,
                    downloadURL: o.url, homepage: o.homepage ?? o.url, note: o.note, source: source,
                    checkedAt: now, releaseDate: o.releaseDate, notes: o.notes,
                    suppressedBeta: o.suppressedBeta ? true : nil)
    }


    struct Outcome {
        var status: CheckStatus
        var latest: String?
        var url: String?
        var homepage: String? = nil
        var note: String?
        var releaseDate: Date?
        var notes: String?
        /// 官网安装包指纹（只给安装包、不给版本号的 App 用）
        var marker: String? = nil
        /// 这条结果是被「不接收测试版」这个开关压下去的（源里最新的其实是 beta）。
        /// 切开关时要靠这个标记重查，别再拿中文提示文案做判断依据。
        var suppressedBeta: Bool = false
    }

    static func sparkle(feed: String, current: String, build: String?, allowBeta: Bool) async -> Result<Outcome, Net.SourceError> {
        let body: String
        switch await Net.textResult(feed) {
        case .success(let s): body = s
        case .failure(let e): return .failure(e)
        }
        guard !body.isEmpty else { return .failure(.empty) }
        let items = AppcastParser().parse(Data(body.utf8))
        guard !items.isEmpty else {
            // 有的源早就废了，301 跳到一张宣传/追踪页：HTTP 200、内容是 HTML，
            // 说「更新源没有响应」是错怪了网络，得说清是源地址失效。
            let head = body.prefix(600).lowercased()
            if head.contains("<html") || head.contains("<!doctype html") {
                return .failure(.notAppcast)
            }
            return .failure(.noItems)
        }

        // appcast 里条目按新到旧排列，取第一条「正式版 + 本机系统能装」的。
        // 带 <sparkle:channel> 的（beta 通道）和版本号里带 Beta/RC 的一律跳过，
        // 除非用户勾了「接收测试版」，或者本机装的就是测试版（他本来就在尝鲜通道上）。
        let compareBeta = allowBeta || isPrereleaseVersion(current)
        var sawAnyVersioned = false
        var sawOnlyPrerelease = true
        for it in items {
            guard let v = it.marketingVersion else { continue }
            sawAnyVersioned = true
            let isBeta = (it.channel?.isEmpty == false) || isPrereleaseVersion(v)
            if !isBeta { sawOnlyPrerelease = false }
            if !compareBeta, isBeta { continue }
            guard systemSatisfies(it.minSystem) else { continue }
            let latest = v
            // 有的 Sparkle 源把构建号写进 title，本机装的已经是这个包 → 已是最新；
            // 括号里带构建号的（Dia 的 1.58.0 (91297)）也一样：构建号跟本机
            // CFBundleVersion 对上就是同一个包，版本号根本没变。
            if latestIsInstalledBuild(latest, current: current, build: build)
                || sameBuild(it.buildVersion ?? it.marketingBuild, build) {
                return .success(Outcome(status: .upToDate, latest: latest,
                                        url: it.enclosure ?? it.link ?? feed,
                                        homepage: siteFromFeed(it.link) ?? siteFromFeed(feed),
                                        note: nil,
                                        releaseDate: parseRFC822(it.pubDate),
                                        notes: plainNotes(it.notes)))
            }
            let newer = Ver.isNewer(latest, than: current)
            var notes = plainNotes(it.notes)
            if notes == nil, newer, let link = it.notesLink, let html = await Net.text(link) {
                notes = plainNotes(html)
            }
            // notes 不管是不是新版本都存下来：点开「其他」页里已是最新的 App，
            // 也该能看到它这一版更新了什么
            return .success(Outcome(status: newer ? .updateAvailable : .upToDate,
                                    latest: latest,
                                    url: it.enclosure ?? it.link ?? feed,
                                    homepage: siteFromFeed(it.link) ?? siteFromFeed(feed),
                                    note: nil,
                                    releaseDate: parseRFC822(it.pubDate),
                                    notes: notes))
        }
        // 更新源里只有测试版（比如作者开了 beta 通道、正式版还没跟上）：
        // 本机装的就是最新正式版，安静地算「已是最新」，别报更新也别报失败。
        if !compareBeta, sawAnyVersioned, sawOnlyPrerelease {
            return .success(Outcome(status: .upToDate, latest: current, url: feed, homepage: siteFromFeed(feed),
                                    note: "只跟正式版比：更新源里最新的是测试版（\(items.compactMap { $0.marketingVersion }.first ?? "beta")）",
                                    suppressedBeta: true))
        }
        // 走到这里说明条目里有版本号，但没有一条能装在本机系统上
        return .failure(sawAnyVersioned ? .incompatibleSystem : .noItems)
    }

    // MARK: - electron-updater

    /// Electron 应用的官方更新通道。版本号就在 `latest-mac.yml` 的顶格 `version:` 里，
    /// 比 cask 新得多也准得多（cask 靠社区 PR，滞后几天是常态）。
    ///
    /// 候选地址按序试：`latest-mac.yml` 优先，channel 专属名兜底。
    /// （Notion 写着 `channel: arm64`，但它没有 arm64-mac.yml —— 先试那个会白等一次超时。）
    static func electron(_ app: InstalledApp, feed: ElectronFeed,
                         allowBeta: Bool) async -> Result<Outcome, Net.SourceError> {
        // github 型（洛雪音乐、zyfun）：版本号在 Releases 里，不必下 yml
        if let repo = feed.githubRepo {
            let page = "https://github.com/\(repo)/releases"
            guard let r = await Rules.githubRepo(app: app, repo: repo,
                                                 downloadPage: page, allowBeta: allowBeta)
            else { return .failure(.noItems) }
            var o = r
            if o.homepage == nil { o.homepage = page }
            return .success(o)
        }

        var lastError: Net.SourceError = .empty
        for candidate in feed.candidates {
            switch await Net.textResult(candidate) {
            case .failure(let err):
                lastError = err
            case .success(let body):
                // 200 + HTML 是常见坑：地址失效后站点把 404 页面用 200 回出来（幕布就是）。
                // 不先挡掉，正则能在网页里翻出乱七八糟的数字当版本号。
                let head = body.drop { $0 == "\n" || $0 == "\r" || $0 == " " }
                if head.first == "<" {
                    lastError = .notUpdateManifest
                    continue
                }
                guard let latest = ElectronUpdater.parse(latestMacYML: body) else {
                    lastError = .notUpdateManifest
                    continue
                }
                guard plausible(latest.version, vs: app.version) else {
                    lastError = .mismatchedVersion
                    continue
                }
                // 下载地址：yml 和安装包同目录，相对文件名直接拼
                let dir = candidate.split(separator: "/").dropLast().joined(separator: "/")
                let url = latest.fileName.map { "\(dir)/\($0)" } ?? candidate
                return .success(Rules.verdict(app, latest: latest.version, url: url,
                                              releaseDate: latest.releaseDate, allowBeta: allowBeta))
            }
        }
        return .failure(lastError)
    }

    /// electron 清单里的版本号和本机是不是同一套编号。
    ///
    /// 最典型的坑是抖音直播伴侣：包内的 app-update.yml 指向抖音自己的通用更新服务
    /// （tron-demo），那份 latest-mac.yml 里写的是框架版本 1.0.2，App 本身却是 10.0.5。
    /// 直接采用就会天天挂着「官方源当前是 1.0.2，你装的版本更高（可能是内测版）」——
    /// 纯噪音。判据只要求「主版本号不脱节」，正常的跨大版本升级（1.x → 2.x）仍放行。
    static func plausible(_ latest: String, vs current: String) -> Bool {
        func major(_ v: String) -> Int? { v.split(separator: ".").first.flatMap { Int($0) } }
        guard let a = major(latest), let b = major(current) else { return true }
        return abs(a - b) <= 1
    }

    /// iTunes lookup 的一条记录，只留判断版本要用的几样东西。
    /// 抽出来是因为两条路都要用它：商店装的 App（`appStore`），
    /// 以及「商店里也卖、但这台机器装的是独立版」的 App（`appStoreFallback`）。
    struct StoreRecord {
        var version: String
        var page: String?
        var seller: String?
        var release: Date?
        var notes: String?
        /// 这条记录能不能代表 Mac 版的版本号。
        /// kind=mac-software 当然是；kind=software 但 features 带 iosUniversal 的
        /// 「一份通用 App」（MindNode、APTV、Notability）也算——iOS / iPad / Mac
        /// 共用同一个版本号。其余 kind=software 的是 iOS 主记录，版本号跟 Mac 包不是一套。
        var isMacRecord: Bool
    }

    /// 查一条商店记录。查不到（下架、bundle id 对不上、网络故障）返回 nil。
    static func storeRecord(bundleId: String, country: String) async -> StoreRecord? {
        // 加时间戳：Apple CDN 会把 iTunes lookup 结果缓存 24h，
        // 我们虽然已经关了 URLSession 缓存，但 Akamai 中间层可能还是按 URL 缓存，
        // 加个 &_=timestamp 让每次请求的 URL 都不一样，彻底绕开。
        let url = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(country)&_=\(Int(Date().timeIntervalSince1970))"
        guard let obj = await Net.json(url) as? [String: Any],
              let count = obj["resultCount"] as? Int, count > 0,
              let results = obj["results"] as? [[String: Any]],
              let first = results.first,
              let version = first["version"] as? String, !version.isEmpty else { return nil }
        let features = (first["features"] as? [String]) ?? []
        let isMac = (first["kind"] as? String) == "mac-software" || features.contains("iosUniversal")
        return StoreRecord(
            version: version,
            page: first["trackViewUrl"] as? String,
            // sellerUrl 是开发者自己的官网（Compressor → apple.com/mac/compressor …），
            // 比商店产品页更像「软件网站」
            seller: (first["sellerUrl"] as? String).flatMap { URL(string: $0)?.absoluteString },
            release: parseISO8601(first["currentVersionReleaseDate"] as? String),
            notes: plainNotes(first["releaseNotes"] as? String),
            isMacRecord: isMac)
    }

    static func appStore(bundleId: String, name: String, current: String, build: String?, installedAt: Date?,
                         country: String, allowBeta: Bool) async -> Outcome? {
        guard let rec = await storeRecord(bundleId: bundleId, country: country) else { return nil }
        var latest = rec.version
        var page = rec.page
        let seller = rec.seller
        var release = rec.release

        // 非 Mac 记录（kind=software 又不带 iosUniversal）说明这是 iOS 主记录：
        // version/更新说明都是 iPhone 版的，接口根本不提供 Mac 版的版本号
        //（Mac App Store 应用里显示的才是 Mac 版，二者经常差一个小版本）。
        var isIOSPrimaryRecord = !rec.isMacRecord

        // Apple 自家 App（Pages / Numbers / Keynote、Final Cut、Logic 这些 Creator Studio）
        // 的 bundleId 跟 iOS 版是同一个，lookup 只会给 iOS 主记录 —— Final Cut 甚至返回 3.x。
        // 它们的 Mac 版在商店里是独立记录，按名字搜 macSoftware 就能拿到真正的 Mac 版本。
        if isIOSPrimaryRecord, bundleId.hasPrefix("com.apple."),
           let mac = await appleMacStoreRecord(name: name, country: country) {
            latest = mac.version
            page = mac.page ?? page
            release = mac.release ?? release
            isIOSPrimaryRecord = false
        }

        // 它要是说「比本机新」，不能当 Mac 版更新的证据——宁可说「核对不了」，别误报。
        if isIOSPrimaryRecord, Ver.isNewer(latest, than: current) {
            return Outcome(status: .unknown, latest: nil, url: page, homepage: seller,
                           note: "商店接口只提供它 iOS 版的版本号（\(latest)），Mac 版请对照 App Store 应用内的页面")
        }

        // 商店接口偶尔也会给构建号（开发者把 build 填进 version 字段）
        if latestIsInstalledBuild(latest, current: current, build: build) {
            return Outcome(status: .upToDate, latest: latest, url: page, homepage: seller,
                           releaseDate: release)
        }

        // 有些开发者发版时没同步 Mac 包里的 CFBundleShortVersionString，
        // 导致「商店 1.13、包内写着 1.4」。Apple 比的是构建号，认为已最新；
        // 这里用安装时间兜底：包比商店那次发布还新，就说明拿到的就是最新包。
        if Ver.isNewer(latest, than: current), let installedAt, let release,
           installedAt > release.addingTimeInterval(60 * 60) {
            return Outcome(status: .upToDate, latest: latest, url: page, homepage: seller,
                           note: "商店版本是 \(latest)，但本机包内标注 \(current)：开发者没同步 Mac 包的版本号，App Store 也认为已是最新",
                           releaseDate: release)
        }

        if !(allowBeta || isPrereleaseVersion(current)), isPrereleaseVersion(latest) {
            return Outcome(status: .upToDate, latest: current, url: page, homepage: seller,
                           note: "只跟正式版比：商店里最新的是测试版（\(latest)）", releaseDate: release,
                           suppressedBeta: true)
        }
        let isNewer = Ver.isNewer(latest, than: current)
        // 商店给的版本号比包内标注的还低：Apple 这个接口对「iOS 和 Mac 是同一个商品」的 App
        // （Final Cut 的 com.apple.FinalCutApp、Logic、MacWhisper）返回的是 iOS 那边的版本号，
        // 跟 Mac 包压根不是一套，没法比 —— 按已是最新算，别硬凑一个假更新出来
        let storeLooksOlder = !isNewer && Ver.isNewer(current, than: latest)
        // 同上：不是新版本也留着更新说明，点开能看
        return Outcome(status: isNewer ? .updateAvailable : .upToDate,
                       latest: latest, url: page, homepage: seller,
                       note: storeLooksOlder
                           ? "商店接口给的是 \(latest)，本机包标注 \(current)：这类通用 App 商店返回的是 iOS 版本号，跟 Mac 包没法比，先按已是最新算"
                           : nil,
                       releaseDate: release,
                       notes: rec.notes)
    }

    /// 「商店兜底」：不是从商店装的（包内没有收据），但商店里也有同一个 App。
    ///
    /// 为什么只能当兜底、不能抢第一顺位：商店版和独立版的发版节奏不一样，商店版经常落后
    /// （PastePal 商店 2.17.0 / 独立版 2.22.4）。appcast / cask / 官网全都问不出结果时，
    /// 拿商店记录顶上 —— 那也比显示「检测失败」或「无检测源」有用。
    /// 唯一例外是 `KnownAppStore` 里标了 `.preferred` 的（MindNode）：商店版和独立版
    /// 共用同一套 2026.x 编号，商店就是它最快最稳的那条路。
    static func appStoreFallback(_ app: InstalledApp, allowBeta: Bool) async -> Outcome? {
        guard let bid = app.bundleId, !app.isAppStore else { return nil }
        async let cn = storeRecord(bundleId: bid, country: "cn")
        async let us = storeRecord(bundleId: bid, country: "us")
        // cn / us 各查一次取版本高的那条，原因同 appStore：两个区的 CDN 刷新时间不一致
        let records = [await cn, await us].compactMap { $0 }.filter(\.isMacRecord)
        guard let best = records.max(by: { Ver.compare($0.version, $1.version) == .orderedAscending })
        else { return nil }
        // 同一个 bundle id 也可能被作者换过产品线，商店里那条是另一个编号体系。
        // 主版本号脱节就不认 —— 宁可不给源，也别拿一个看着像更新的数字吓人。
        guard plausible(best.version, vs: app.version) else { return nil }
        return storeFallbackOutcome(best, current: app.version, build: app.build, allowBeta: allowBeta)
    }

    /// 商店记录 → 检测结果。拆成纯函数，测试可以直接喂一条记录，不用联网。
    static func storeFallbackOutcome(_ best: StoreRecord, current: String, build: String?,
                                     allowBeta: Bool) -> Outcome {
        let latest = best.version
        if latestIsInstalledBuild(latest, current: current, build: build) {
            return Outcome(status: .upToDate, latest: latest, url: best.page, homepage: best.seller,
                           releaseDate: best.release, notes: best.notes)
        }
        if !(allowBeta || isPrereleaseVersion(current)), isPrereleaseVersion(latest) {
            return Outcome(status: .upToDate, latest: current, url: best.page, homepage: best.seller,
                           note: "只跟正式版比：商店里最新的是测试版（\(latest)）",
                           releaseDate: best.release, suppressedBeta: true)
        }
        if Ver.isNewer(latest, than: current) {
            return Outcome(status: .updateAvailable, latest: latest, url: best.page, homepage: best.seller,
                           note: "版本号来自 App Store（这个包不是商店装的，商店版和独立版可能不同步）",
                           releaseDate: best.release, notes: best.notes)
        }
        // 多数情况是这个：本机独立版比商店版还新，那商店就是「没有更新」，别报更新
        return Outcome(status: .upToDate, latest: latest, url: best.page, homepage: best.seller,
                       note: Ver.isNewer(current, than: latest)
                           ? "App Store 上的是 \(latest)，本机独立版 \(current) 更新（商店版发版通常慢一些）"
                           : nil,
                       releaseDate: best.release, notes: best.notes)
    }

    /// Apple 自家 App 的 Mac 版记录。    /// Pages / Numbers / Keynote / Final Cut / Logic 这些「Creator Studio」App 的 bundleId
    /// 跟 iOS 版共用，`lookup?bundleId=` 只会返回 iOS 主记录（Final Cut 甚至只有 3.x）。
    /// Mac 版在商店里是独立记录，`search?entity=macSoftware` 按名字能搜到；
    /// 这里挑「名字对得上、卖家是 Apple、版本号最高」的那条。
    private static func appleMacStoreRecord(name: String,
                                            country: String) async -> (version: String, page: String?, release: Date?)? {
        let term = name.replacingOccurrences(of: " Creator Studio", with: "")
        guard !term.isEmpty,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let obj = await Net.json("https://itunes.apple.com/search?term=\(encoded)&country=\(country)&entity=macSoftware&limit=25&_=\(Int(Date().timeIntervalSince1970))") as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }
        let lowered = term.lowercased()
        let hits = results.filter { r in
            guard let seller = r["sellerName"] as? String, seller.contains("Apple"),
                  let title = r["trackName"] as? String else { return false }
            return title.lowercased().hasPrefix(lowered)
        }
        guard var best = hits.first, var bestVersion = best["version"] as? String else { return nil }
        for r in hits.dropFirst() {
            guard let v = r["version"] as? String else { continue }
            if Ver.isNewer(v, than: bestVersion) {
                best = r
                bestVersion = v
            }
        }
        return (bestVersion, best["trackViewUrl"] as? String,
                parseISO8601(best["currentVersionReleaseDate"] as? String))
    }
}

// MARK: - 厂商规则

struct VendorRule {
    let matches: (InstalledApp) -> Bool
    /// 第二个参数是上一轮的检测结果（官网只给安装包的那些要比指纹，别的一律忽略），
    /// 第三个是 allowBeta（用户勾了「接收测试版」才为 true）
    let run: (InstalledApp, CheckResult?, Bool) async -> Checker.Outcome?
}

enum Rules {
    /// 把一个「官方最新版本号」变成检测结果；本机反而更高时给个说明
    static func verdict(_ app: InstalledApp, latest: String, url: String, releaseDate: Date? = nil,
                        allowBeta: Bool = false) -> Checker.Outcome {
        // 抓到的要是测试版（2.0.0-beta.3、1.2rc1 这种），就不算更新：只跟正式版比。
        // 例外：本机装的本身就是测试版，那就照常比（用户已经在尝鲜通道上）。
        if !(allowBeta || isPrereleaseVersion(app.version)), isPrereleaseVersion(latest) {
            return Checker.Outcome(status: .upToDate, latest: app.version, url: url, homepage: url,
                                   note: "只跟正式版比：更新源里最新的是测试版（\(latest)）",
                                   releaseDate: releaseDate, suppressedBeta: true)
        }
        // 官网页面抓到的是构建号：本机装的已是这个包
        if latestIsInstalledBuild(latest, current: app.version, build: app.build) {
            return Checker.Outcome(status: .upToDate, latest: latest, url: url, homepage: url,
                                   releaseDate: releaseDate)
        }
        let newer = Ver.isNewer(latest, than: app.version)
        // 只有「本机反而更高」时才需要解释，版本相同或更新都保持沉默
        let note: String? = (!newer && Ver.isNewer(app.version, than: latest))
            ? "官方源当前是 \(latest)，你装的版本更高（可能是内测版）"
            : nil
        return Checker.Outcome(status: newer ? .updateAvailable : .upToDate,
                               latest: latest, url: url, homepage: url,
                               note: note, releaseDate: releaseDate)
    }

    /// 官网页面里抓版本号
    static func pageRegex(app: InstalledApp, page: String, pattern: String,
                          downloadPage: String, allowBeta: Bool) async -> Checker.Outcome? {
        guard let html = await Net.text(page) else { return nil }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        let found = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var versions: [String] = []
        for m in found where m.numberOfRanges > 1 {
            versions.append(ns.substring(with: m.range(at: 1)))
        }
        guard let latest = versions.max(by: { Ver.compare($0, $1) == .orderedAscending }) else { return nil }
        return verdict(app, latest: latest, url: downloadPage, allowBeta: allowBeta)
    }

    /// 官网页面挂的可能是老包，最新包在其背后的安装包接口里（酷家乐就是这种）。
    /// 接口 JSON 形如：
    /// {"c":"0","m":"","d":{"url":"…/Kujiale-12.4.4-stable-zhannei_denglu.dmg","version":"12.4.4",…}}
    static func installerAPI(app: InstalledApp, endpoint: String,
                             downloadPage: String, allowBeta: Bool) async -> Checker.Outcome? {
        guard let obj = await Net.json(endpoint) as? [String: Any],
              let d = obj["d"] as? [String: Any],
              let version = d["version"] as? String, !version.isEmpty
        else { return nil }
        return verdict(app, latest: version, url: downloadPage, allowBeta: allowBeta)
    }

    /// MindNode 发布说明页里的版本号：取时间轴里最大的那个。
    /// 页面结构（2026-11 实测）：
    ///   <li id="2026.7.2" class="releasesTimeline__release ">
    ///     <h2 class="releasesTimeline__version"><time dateTime="2026-11-10">2026.7.2</time>
    /// 它没有 appcast（SUFeedURL 空、官网 appcast.xml 是 404 的网页），这页是唯一稳定来源。
    /// 拆成纯函数是为了测试能直接喂一段 HTML，不用联网。
    static func mindNodeVersion(in html: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: #"releasesTimeline__version"><time[^>]*>([0-9][0-9.]*)</time>"#) else { return nil }
        let ns = html as NSString
        let found = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let versions = found.filter { $0.numberOfRanges > 1 }
            .map { ns.substring(with: $0.range(at: 1)) }
        return versions.max { Ver.compare($0, $1) == .orderedAscending }
    }

    /// GitHub Releases 最新 tag
    static func githubRepo(app: InstalledApp, repo: String, downloadPage: String,
                           allowBeta: Bool) async -> Checker.Outcome? {        switch await Net.githubLatestRelease(repo) {
        case .failure(let err):
            if err.isRateLimited {
                // 403/429 不是「这个 App 坏了」，是配额用完了：如实说，别让用户以为软件出问题
                return Checker.Outcome(
                    status: .failed, latest: nil, url: downloadPage, homepage: downloadPage,
                    note: "GitHub 接口限流（未登录时每小时 60 次，同一网络下多台 Mac 共用配额）；过一会儿再看，或把扫描间隔调长")
            }
            return nil   // 404（仓库没了）和其他状态码：沿用旧行为，当作抓不到
        case .success(let obj):
            guard let obj, let tag = obj["tag_name"] as? String else { return nil }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return verdict(app, latest: latest, url: downloadPage, allowBeta: allowBeta)
        }
    }

    /// 官网只给安装包、不给版本号的 App（扣子桌面端就是）：拿不到「最新版本是几」，
    /// 那就记下官网当前那个安装包（文件名里的构建时间戳），下次换了包再提醒。
    ///
    /// 第一次只记录、不提示 —— 不然装完第一次检查就报「有新版本」，纯吓人。
    /// 用户要是自己已经把 App 更新过了（.app 的创建时间晚于上次检查），也当成已装上。
    static func officialPackage(app: InstalledApp, previous: CheckResult?,
                                shortLink: String, downloadPage: String,
                                name: String) async -> Checker.Outcome? {
        guard let final = await Net.redirectTarget(shortLink) else { return nil }
        let file = final.lastPathComponent
        guard file.lowercased().hasSuffix(".dmg") else { return nil }
        let url = final.absoluteString
        // 只认构建号（v1792397273）：同一个构建换个渠道包（macOS / Intel / mac64）不算新版本，
        // 否则短链哪天换条渠道就会被判成「有新安装包」。
        let marker = packageMarker(file)
        let stamp = packageStamp(marker)

        guard let prev = previous?.marker else {
            return Checker.Outcome(status: .upToDate, latest: nil, url: url, homepage: downloadPage,
                                   note: "已记下官网当前的安装包（\(stamp)）；官网换包了会提醒你",
                                   marker: marker)
        }
        if prev == marker {
            return Checker.Outcome(status: .upToDate, latest: nil, url: url, homepage: downloadPage,
                                   marker: marker)
        }
        if let lastCheck = previous?.checkedAt, let installed = app.installedAt, installed > lastCheck {
            return Checker.Outcome(status: .upToDate, latest: nil, url: url, homepage: downloadPage,
                                   note: "官网有新的安装包（\(stamp)），本机已经更新过了",
                                   marker: marker)
        }
        return Checker.Outcome(status: .updateAvailable, latest: nil, url: url, homepage: downloadPage,
                               note: "\(name) 官网不写版本号，按安装包变化提醒：官网已经有 \(stamp) 的新包",
                               marker: marker)
    }

    /// 安装包文件名里的构建号：coze_space_docs_macos_v1792397273_c36e_1792399987.dmg → v1792397273
    private static func packageMarker(_ file: String) -> String {
        if let re = try? NSRegularExpression(pattern: #"_v(\d{8,})_"#),
           let m = re.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)),
           let r = Range(m.range(at: 1), in: file) {
            return "v" + file[r]
        }
        return file
    }

    /// 构建号本身就是打包时间戳（1792397273 → 10月19日的包），拿它说人话
    private static func packageStamp(_ marker: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(\d{10})"#),
              let m = re.firstMatch(in: marker, range: NSRange(marker.startIndex..., in: marker)),
              let r = Range(m.range(at: 1), in: marker),
              let ts = TimeInterval(marker[r]) else { return "新" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: Date(timeIntervalSince1970: ts)) + "的包"
    }

    static let all: [VendorRule] = [
        // 扣子桌面端：官网「下载桌面端」是短链，落地到 CDN 的 dmg，文件名里只有构建时间戳、
        // 没有 1.1.x 这种版本号；它自己的更新源（electron-updater）在字节内网域名上，
        // 公网连不上。所以走「官网安装包指纹」这条路。
        VendorRule(matches: { $0.bundleId == "cn.coze.desktop" }) { app, previous, _ in
            await officialPackage(app: app, previous: previous,
                                  shortLink: "https://ugapk.com/FJvCs",
                                  downloadPage: "https://www.coze.cn/",
                                  name: "扣子")
        },
        // 酷家乐：官网下载页（activity/136）里的包是死的（页面上仍挂着 2023-11 的 12.3.13），
        // 最新包由页面背后的安装包接口返回，用它的 d.version 才算官方当前版本。
        VendorRule(matches: { $0.bundleId == "com.kujiale.mac.kujiale" }) { app, _, allowBeta in
            await installerAPI(app: app,
                               endpoint: "https://www.kujiale.com/desktop-publish/api/installer"
                                   + "?channel=zhannei_denglu&desktopKey=kujiale&target=mac&arch=all",
                               downloadPage: "https://www.kujiale.com/activity/136",
                               allowBeta: allowBeta)
        },
        // 微信
        VendorRule(matches: { $0.bundleId == "com.tencent.xinWeChat" }) { app, _, allowBeta in
            await pageRegex(app: app,
                            page: "https://mac.weixin.qq.com/",
                            pattern: #"WeChatMac_([0-9]+\.[0-9]+\.?[0-9]*)\.dmg"#,
                            downloadPage: "https://mac.weixin.qq.com/",
                            allowBeta: allowBeta)
        },
        // QQ
        VendorRule(matches: { $0.bundleId == "com.tencent.QQ" || $0.bundleId == "com.tencent.qq" }) { app, _, allowBeta in
            await pageRegex(app: app,
                            page: "https://im.qq.com/macqq/index.shtml",
                            pattern: #"QQ_v([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+\.dmg"#,
                            downloadPage: "https://im.qq.com/macqq/",
                            allowBeta: allowBeta)
        },
        // Obsidian
        VendorRule(matches: { $0.bundleId == "md.obsidian" }) { app, _, allowBeta in
            await githubRepo(app: app, repo: "obsidianmd/obsidian-releases",
                             downloadPage: "https://obsidian.md/download", allowBeta: allowBeta)
        },
        // Google Chrome：官方 versionhistory 接口在国内不通，改用 Chrome for Testing 的 stable 版本
        VendorRule(matches: { $0.bundleId == "com.google.Chrome" }) { app, _, allowBeta in
            guard let obj = await Net.json("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json") as? [String: Any],
                  let channels = obj["channels"] as? [String: Any],
                  let stable = channels["Stable"] as? [String: Any],
                  let latest = stable["version"] as? String else { return nil }
            return verdict(app, latest: latest, url: "https://www.google.com/chrome/", allowBeta: allowBeta)
        },
        // WPS Office
        VendorRule(matches: { $0.bundleId == "com.kingsoft.wpsoffice.mac" }) { app, _, allowBeta in
            await pageRegex(app: app,
                            page: "https://www.wps.cn/product/wpsmac",
                            pattern: #"(1[0-9]\.[0-9]+\.[0-9]{4,6})"#,
                            downloadPage: "https://www.wps.cn/product/wpsmac",
                            allowBeta: allowBeta)
        },
        // Motrix
        VendorRule(matches: { $0.bundleId == "app.motrix.native" }) { app, _, allowBeta in
            await githubRepo(app: app, repo: "agalwood/Motrix",
                             downloadPage: "https://motrix.app/", allowBeta: allowBeta)
        },
        // Anki
        VendorRule(matches: { $0.bundleId == "net.ankiweb.anki" }) { app, _, allowBeta in
            await githubRepo(app: app, repo: "ankitects/anki",
                             downloadPage: "https://apps.ankiweb.net/", allowBeta: allowBeta)
        },
        // 洛雪音乐
        VendorRule(matches: { $0.bundleId == "cn.toside.music.desktop" }) { app, _, allowBeta in
            await githubRepo(app: app, repo: "lyswhut/lx-music-desktop",
                             downloadPage: "https://github.com/lyswhut/lx-music-desktop/releases",
                             allowBeta: allowBeta)
        },
        // UVR（Ultimate Vocal Remover）
        VendorRule(matches: { $0.id == "UVR" || $0.bundleId == "UVR" }) { app, _, allowBeta in
            await githubRepo(app: app, repo: "Anjok07/ultimatevocalremovergui",
                             downloadPage: "https://github.com/Anjok07/ultimatevocalremovergui/releases",
                             allowBeta: allowBeta)
        },
        // MindNode：第一顺位是商店（见 KnownAppStore 的 `.preferred` —— 商店里是「通用 App」，
        // 版本号就是这个 2026.x，几百毫秒就回）。这条规则是商店那条路走不通时的兜底：
        // 包内 SUFeedURL 是空的（Sparkle 的 feed 写在代码里），官网 appcast.xml 只会 308
        // 到一张 404 网页；能拿到版本号的只剩发布说明页的时间轴。
        // 这一页慢（实测 6~8 秒），用单独放开的 30 秒超时，别跟别的源抢 15 秒的线。
        VendorRule(matches: { $0.bundleId == "com.ideasoncanvas.mindnode" }) { app, _, allowBeta in
            let page = "https://mindnode.com/releases/"
            guard let body = await Net.text(page, timeout: 30),
                  let latest = mindNodeVersion(in: body) else {
                // 页面没打开 / 改版了：如实说清楚，别用「官网页面没抓到版本号」这种
                // 让人以为是 App 出问题的说法。下一次定时检查会重试。
                return Checker.Outcome(status: .failed, latest: nil, url: page, homepage: page,
                                       note: "MindNode 官网发布页没打开（这页偏慢，网络不稳时会这样）")
            }
            return verdict(app, latest: latest, url: page, allowBeta: allowBeta)
        }
    ]

    static func match(_ app: InstalledApp) -> VendorRule? {
        all.first { $0.matches(app) }
    }
}
