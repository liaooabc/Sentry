import AppKit
import CoreServices
import Foundation

enum Scanner {
    static let selfBundleId = "com.hushixiong.sentry"

    static func scan() -> [InstalledApp] {
        var roots = ["/Applications"]
        let home = NSHomeDirectory()
        roots.append(home + "/Applications")

        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in roots {
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            // 下钻四层：/Applications/X.app（1）、Adobe 套件的 /Applications/Adobe X/Y.app（2），
            // 以及 Setapp、DaVinci Resolve 这类「厂商目录/子目录/App」的三层结构，多留一层余量。
            // 深度限死后递归不会爆，不需要再挂一个全局条目计数器当熔断
            // （那种计数一旦撞上限，排在后面的 App 会被整批丢掉）。
            // .app 是 bundle，skipsPackageDescendants 本来就不会钻进去，四层只是多扫几个空目录。
            for case let url as URL in e {
                let rel = url.path.replacingOccurrences(of: root + "/", with: "")
                if rel.components(separatedBy: "/").count > 4 {
                    e.skipDescendants()
                    continue
                }
                guard url.pathExtension == "app" else { continue }
                e.skipDescendants()

                guard let app = readApp(at: url.path) else { continue }
                if seen.contains(app.id) { continue }
                seen.insert(app.id)
                apps.append(app)
            }
        }

        return apps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// _MASReceipt 存在 ≠ 真是商店装的：第三方直装版会塞一份假收据，
    /// 里面就一行安装站网址（20 字节），雷达却把它当商店包，只能去 iTunes 查，
    /// 商店查不到就整条变「无检测源」，连 Sparkle / Cask 都不试了。
    /// 真收据是 Apple 签发的 ASN.1，4KB 上下、带签发者串；少数 App 收据暂时是空的（0 字节），
    /// 那种仍按商店包算，免得把真商店包推去比官网版本号。
    static func hasAppStoreReceipt(at path: String) -> Bool {
        let receipt = path + "/Contents/_MASReceipt/receipt"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: receipt)), !data.isEmpty else {
            return FileManager.default.fileExists(atPath: receipt)
        }
        if data.count >= 1024 { return true }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("Apple Inc.") || text.contains("Apple Worldwide Developer Relations")
    }

    /// 面板里显示的名字 = Finder / 启动台里显示的那个名字。
    /// 优先用 Spotlight 的 `kMDItemDisplayName`——它就是系统给这个包定的显示名，最准：
    /// - `Doubao.app` → **豆包**（名字在 zh_CN.lproj 里，`FileManager.displayName` 会退回 Doubao）；
    /// - `Compressor Creator Studio.app` → **Compressor**（包目录名不是显示名）；
    /// - `Affinity.app` → **Affinity**（不是 CFBundleDisplayName 的 "Affinity for China"）。
    /// 取不到（没建索引的卷、刚装还没入库）再退回 `FileManager.displayName`，最后退回文件名。
    static func displayName(forPath path: String) -> String {
        if let name = spotlightDisplayName(path), !name.isEmpty { return name }
        return fallbackDisplayName(path)
    }

    /// Spotlight 那条路走不通时的退路：`FileManager.displayName` → 文件名。
    /// 单独拆出来，是因为 `readApp` 已经自己查过 Spotlight（顺手取「最近使用」），
    /// 不该为了拿这个名字再查一遍。
    static func fallbackDisplayName(_ path: String) -> String {
        let shown = FileManager.default.displayName(atPath: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !shown.isEmpty, shown != ".app" { return shown }
        return fileNameStem(of: path)
    }

    /// Spotlight 记的显示名（和 Finder 里看到的一致），取不到返回 nil
    static func spotlightDisplayName(_ path: String) -> String? {
        spotlightInfo(path).name
    }

    /// 一次 MDItem 查询取两样：显示名 + 最近使用时间。
    /// 分两次查要走两遍 Spotlight 索引，120 个 App 就是白白多一倍时间。
    static func spotlightInfo(_ path: String) -> (name: String?, lastUsed: Date?) {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else {
            return (nil, nil)
        }
        var name: String?
        if let raw = MDItemCopyAttribute(item, kMDItemDisplayName) as? String {
            // 有 App 的文件名自带尾部空格（"Comfy .app"），显示名会连空格一起带出来
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = trimmed }
        }
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        return (name, lastUsed)
    }

    /// 只刷「最近使用」时间（不动版本、不动检测结果）。
    /// 面板打开时调一次：这东西随用户开 App 一直在变，扫描那一刻的值很快就旧了。
    static func lastUsedMap(paths: [String]) -> [String: Date] {
        var map: [String: Date] = [:]
        for path in paths {
            guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            map[path] = date
        }
        return map
    }

    /// 兜底：文件名去掉 .app（`displayName` 意外取不到时用）
    static func fileNameStem(of path: String) -> String {
        // 去掉尾部斜杠，免得 "/Applications/X.app/" 取到空串
        let trimmedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let base = (trimmedPath as NSString).lastPathComponent
        let stem = base.hasSuffix(".app") ? String(base.dropLast(4)) : base
        return stem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readApp(at path: String) -> InstalledApp? {
        let infoPath = path + "/Contents/Info.plist"
        guard FileManager.default.fileExists(atPath: infoPath),
              let dict = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { return nil }

        let bundleId = dict["CFBundleIdentifier"] as? String
        if bundleId == selfBundleId { return nil }

        // 显示名和「最近使用」一起取：同一次 Spotlight 查询顺手带上，不额外花时间
        let spot = spotlightInfo(path)
        var name = spot.name ?? ""
        if name.isEmpty { name = fallbackDisplayName(path) }
        // 兜底：理论上 .app 不会没名字，真遇到空的就退回 Info.plist 里的名字
        if name.isEmpty {
            name = ((dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
            ?? "0"
        // 构建号单独留着：Office 这类更新源记的是 build（16.114.26102031），
        // 营销版本号是 16.114.1，只比前者必然误报「有新版本」。
        let build = (dict["CFBundleVersion"] as? String) ?? ""

        var feed = dict["SUFeedURL"] as? String
        if let f = feed {
            let low = f.lowercased()
            if low.contains("0.0.0.0") || low.contains("localhost") || low.contains("127.0.0.1") {
                feed = nil
            }
        }

        // Electron 包没有 SUFeedURL，更新地址在 Contents/Resources/app-update.yml 里。
        // 只在没 appcast 时才读：同一个 App 不会两套都用，省一次文件扫。
        let electronFeed = feed == nil ? ElectronUpdater.feed(appPath: path) : nil

        let isMAS = hasAppStoreReceipt(at: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let installedAt = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)

        let isBeta = version.lowercased().contains("beta")
            || version.lowercased().contains("-rc")
            || name.lowercased().contains("beta")

        return InstalledApp(
            id: bundleId ?? path,
            name: name,
            path: path,
            bundleId: bundleId,
            version: version,
            build: build,
            sparkleFeed: feed,
            electronFeed: electronFeed,
            isAppStore: isMAS,
            isBeta: isBeta,
            installedAt: installedAt,
            lastUsedAt: spot.lastUsed
        )
    }
}
