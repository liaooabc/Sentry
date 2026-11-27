import AppKit
import Foundation

/// 数据目录。不挂在 UpdateService 上：Cask 枚举在后台并发 Task 里要用它，
/// 而 UpdateService 是 @MainActor 隔离的（Swift 6 语言模式下会硬报错）。
let SentrySupportDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("Sentry", isDirectory: true)
    let fm = FileManager.default
    // 从「更新雷达」改名为 Sentry：首次启动把旧数据目录整个搬过来，
    // 保住已有的配置、忽略列表和缓存，用户不会丢设置。只在旧目录在、新目录不在时搬一次。
    let legacy = base.appendingPathComponent("UpdateRadar", isDirectory: true)
    if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
        try? fm.moveItem(at: legacy, to: dir)
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

struct InstalledApp: Identifiable, Hashable {
    let id: String          // bundleIdentifier，没有就用路径
    let name: String
    let path: String
    let bundleId: String?
    let version: String
    /// CFBundleVersion。更新源经常写构建号而不是营销版本号（Office: 16.114.26102031），
    /// 少了它就会把「本机已经装着的包」判成新版本。
    let build: String
    let sparkleFeed: String?
    /// Electron 应用的更新源（包内 app-update.yml 推出来的）。
    /// 这类包**没有** SUFeedURL，sparkleFeed 恒为 nil，靠这条才有官方版本号。
    let electronFeed: ElectronFeed?
    let isAppStore: Bool
    let isBeta: Bool
    let installedAt: Date?   // .app 的创建时间，用来判断 Apple 发的是不是最新包
    /// 上次启动时间，取自 Spotlight 的 kMDItemLastUsedDate（「最近使用」排序用）。
    /// 不是 let：面板打开时会补刷一次，用一会儿 App 顺序才不会停在扫描那一刻。
    var lastUsedAt: Date?

    /// 图标里带了浅色/深色两份，画的时候由 AppKit 按当前外观自己挑
    var icon: AppIconPair { IconCache.shared.icon(for: path) }
}

enum CheckStatus: String, Codable {
    case upToDate        // 已是最新
    case updateAvailable // 有新版本
    case unknown         // 没有可用的检测源
    case failed          // 检测出错（网络等）
}

struct CheckResult: Identifiable, Codable, Equatable {
    let bundleId: String
    var status: CheckStatus
    var latest: String?
    var downloadURL: String?
    /// 软件自己的官网（不是下载直链、也不是商店的产品页）。
    /// 左键点一行用它；「打开下载页」才用 downloadURL。
    var homepage: String?
    var note: String?
    var source: String?     // sparkle / appstore / vendor / manual
    var checkedAt: Date
    var releaseDate: Date?  // 新版本的发布/更新时间，用来证明"哪个更新"
    var notes: String?      // 更新详情（从更新源里抓的第一段）
    /// 官网安装包指纹（文件名的构建时间戳）。官网只放安装包、不写版本号的 App
    /// （扣子桌面端）用它判断「官网的包换了没」，因为压根没有版本号可比。
    var marker: String? = nil
    /// 这条结果是被「不接收测试版」开关压下去的（更新源里最新的其实是 beta）。
    /// 切开关时要重查这些 App —— 用结构化标记，别去 match 中文提示文案。
    /// 可选是为了兼容旧版 state.json（没有这个键就是 nil）。
    var suppressedBeta: Bool? = nil

    var id: String { bundleId }
}

/// 顶栏排序方式，三条平铺单选：
/// - name：本地化标准序（中文按拼音，跟 Finder / 访达里看到的一致）
/// - recent：按 Spotlight 记的「最近使用」时间，最近用过的在前
/// - installed：按 .app 的创建时间，最近装的在前（没有创建时间的排在最后）
enum SortMode: String, CaseIterable {
    case name, recent, installed

    var title: String {
        switch self {
        case .name: return "名称"
        case .recent: return "最近使用"
        case .installed: return "安装时间"
        }
    }
}

/// 面板的外观。默认「自动」——跟系统走，这也是 macOS 上所有原生 App 的常规做法。
/// 单独抽出来是因为 `NSApp.appearance` 只认 NSAppearance 对象，
/// 而设置里存的是一个能跨版本解码的字符串。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// 分段控件的文字。用「自动」而不是「跟随系统」：跟系统设置里同一个词，
    /// 三段等宽也放得下（364 的面板里这一行本来就窄）。
    var title: String {
        switch self {
        case .system: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// nil = 交回系统（`NSApp.appearance = nil` 就是「跟随系统」的原生写法）
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 真正把外观落到应用上。只改 `NSApp.appearance` 就够：面板、关于页、引导窗都是本进程的窗口，
    /// 会一起跟着变；菜单栏图标是 template 图，由系统按菜单栏自己的明暗着色，不吃这个设置。
    ///
    /// 切换后要催一遍重绘：玻璃（NSVisualEffectView）和 glassEffect 的材质有自己的缓存，
    /// 纯改 appearance 时偶尔会留着一层旧底，切到深色能看到半截浅色边。
    @MainActor
    static func apply(_ mode: AppAppearance) {
        let target = mode.nsAppearance
        guard NSApp.appearance != target else { return }
        NSApp.appearance = target
        for window in NSApp.windows {
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }
}

struct AppSettings: Codable, Equatable {
    var intervalHours: Double = 6
    var ignored: [String] = []
    var lastCheck: Date?
    /// 只显示有自动检测源的 App（默认开：没源的藏起来，设置里能再打开）。
    /// 可选是为了兼容旧版 state.json 没有这个键。
    var hideUnknown: Bool?
    /// 隐藏检测失败的 App（默认开）。失败多是源暂时抽风，15 分钟后会补查，
    /// 平时不用占列表的位置。
    var hideFailed: Bool?
    /// 可选是为了兼容旧版 state.json 里没有这两个键的情况
    var notifyOnUpdates: Bool?
    var showCount: Bool?
    var lastNotifiedKey: String?
    /// bundleId -> 用户手动确认为最新的那个商店版本号；商店再出新版本时会自动重新提醒
    var dismissed: [String: String]?

    /// 接不接收测试版（beta / rc）更新。默认关：只跟正式版比，别拿 beta 打扰人。
    var receiveBeta: Bool?

    /// 顶栏排序方式，存 SortMode 的 rawValue。用 String? 而不是枚举本身：
    /// 旧版 state.json 里没有这个键，将来万一删掉某个模式，存着老值也不会让整份设置解码失败。
    var sortOrder: String?

    var sort: SortMode { SortMode(rawValue: sortOrder ?? "") ?? .name }

    /// 面板外观，存 AppAppearance 的 rawValue。同样用 String? 兜旧版 state.json；
    /// 存着不认识的值（比如以后删掉某一项）就当「自动」，不让整份设置解码失败。
    var appearance: String?

    var appearanceMode: AppAppearance { AppAppearance(rawValue: appearance ?? "") ?? .system }

    var notifyEnabled: Bool { notifyOnUpdates ?? true }
    var countVisible: Bool { showCount ?? true }
    var receiveBetaEnabled: Bool { receiveBeta ?? false }
    var hideUnknownEnabled: Bool { hideUnknown ?? true }
    var hideFailedEnabled: Bool { hideFailed ?? true }
}

struct Store: Codable {
    var settings: AppSettings = AppSettings()
    var results: [String: CheckResult] = [:]
}

/// 一个 App 在界面上的完整状态
struct AppRow: Identifiable {
    let app: InstalledApp
    let result: CheckResult?

    var id: String { app.id }
    var status: CheckStatus { result?.status ?? .unknown }
    var latest: String? { result?.latest }
    var isUpdate: Bool { status == .updateAvailable }
    var hasSource: Bool { (result?.source != nil && result?.source != "manual") || result?.status == .failed }

    /// 把「GitHub 接口限流（未登录时每小时 60 次…）」这类长 note 压成一句短的
    static func shortReason(_ note: String) -> String? {
        let head = note.split(whereSeparator: { "（(，,；;：:".contains($0) }).first.map(String.init) ?? note
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 12 ? trimmed : String(trimmed.prefix(12)) + "…"
    }

    var subtitle: String {
        switch status {
        case .updateAvailable:
            // 官网只放安装包、没有版本号的那种：只能告诉你「官网换包了」
            guard let latest else { return "\(app.version)　·　官网有新安装包" }
            // 副标题只留「本机版本 → 新版本」，不再追加发布日期
            return "\(app.version)  →  \(latest)"
        case .upToDate:
            if let n = result?.note, n.hasPrefix("手动确认") {
                return "\(app.version)　已确认最新（商店 \(latest ?? "?"))"
            }
            // 更新源里只有测试版时不提示更新，但得让用户知道为什么（不然会以为漏了）
            if result?.note?.hasPrefix("只跟正式版比") == true {
                return "\(app.version)　·　只有测试版更新"
            }
            // 官网页面比本机旧（酷家乐那种页面常年不更新）：把官网看到的写出来，
            // 免得用户以为「加了官网源怎么还是老样子」
            if result?.note?.hasPrefix("官方源当前是") == true, let latest {
                return "\(app.version)　·　官网页面还是 \(latest)"
            }
            return app.version
        case .failed:
            // 状态字在右边那列（⚠ 检测失败），副标题不重复状态字；
            // 有 note 就带一句「为什么失败」，太长的截断（完整原文在悬停提示里）
            if let n = result?.note, let short = AppRow.shortReason(n) {
                return "\(app.version)　·　\(short)"
            }
            return app.version
        case .unknown:
            return app.version
        }
    }
}


/// 一个 App 的图标。NSWorkspace 返回的 NSImage 里自带浅色/深色多套 representation，
/// 交给 AppKit 在绘制时按当前外观自动选，所以这里只存一份（字段名沿用 light/dark，
/// 两个都指向同一张未拍平的图）。
struct AppIconPair {
    let light: NSImage
    let dark: NSImage
}

/// 图标很贵：每次调用都会问 LaunchServices。缓存起来，滚动才不会卡。
final class IconCache {
    static let shared = IconCache()

    private struct Entry {
        let icons: AppIconPair
        /// App 包的修改时间：App 升级换了图标后这里会变，据此重新取图
        let stamp: Date?
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    func icon(for path: String) -> AppIconPair {
        let stamp = IconCache.stamp(of: path)
        lock.lock()
        if let hit = cache[path], hit.stamp == stamp { lock.unlock(); return hit.icons }
        lock.unlock()

        // 不拍平。NSWorkspace 的图标里带着浅色/深色多套 representation，
        // 拍平成位图会把外观钉死在取图那一刻，切系统深浅色就不会变。
        // 照 Sidle 的做法：copy 一份（别污染 NSWorkspace 的共享缓存），只改 size，
        // 让 AppKit 在每次绘制时按当前外观自动选 representation。
        let src = NSWorkspace.shared.icon(forFile: path)
        let copied = (src.copy() as? NSImage) ?? src
        copied.size = NSSize(width: 40, height: 40)
        let icons = AppIconPair(light: copied, dark: copied)

        lock.lock()
        cache[path] = Entry(icons: icons, stamp: stamp)
        lock.unlock()
        return icons
    }

    /// App 被升级后图标可能换掉，所以缓存要跟着包的修改时间走，
    /// 不用重启面板
    private static func stamp(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// 扫描结束后在后台先把图标暖进缓存。
    /// 行里是现取图标的（`row.app.icon`），第一次切到「其他」页时近百个图标
    /// 会在主线程上依次问 LaunchServices + 光栅化，点一下就能卡半秒；
    /// 先在后台备好，切页签就只是换内容。
    func preload(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                _ = self.icon(for: path)
            }
        }
    }

}

// MARK: - 面板尺寸（一处定义，列表行高由它推出来）

/// 面板是固定尺寸的：顶部条和底栏各占一条，中间那截留给列表。
/// 「固定显示 10 个 App、最后一行不被底栏压住」这件事能成立，靠的就是
/// **行高 = 列表可用高度 ÷ 10**，所以行高不写死，跟着下面这几个数一起算。
///
/// 改任何一条都要重看：面板高、顶部条内边距、底栏内边距。
/// 算错的表现是最后一行被底栏裁掉一条边，或者底下露出半行。
enum PanelMetrics {
    static let width: CGFloat = 364
    static let height: CGFloat = 548

    /// 顶部条：页签轨道 26（按钮 20 + 轨道上下各 3）+ 上 12 + 下 8
    static let topBarHeight: CGFloat = 46
    /// 底栏：扫描胶囊与三颗圆钮都是 26，上下各 8
    static let footerHeight: CGFloat = 42

    /// 面板里固定露出的行数
    static let visibleRows: CGFloat = 10

    /// 行的总高：(548 - 46 - 42) / 10 = 46
    static let rowHeight: CGFloat = (height - topBarHeight - footerHeight) / visibleRows
    /// App 图标边长。行高 46 里留 40 给图标，其余是上下各 3pt 的呼吸
    static let iconSide: CGFloat = 40
    /// 行内上下留白：(46 - 40) / 2 = 3
    static let rowVerticalPadding: CGFloat = (rowHeight - iconSide) / 2
}

// MARK: - 手势方向判定

/// 左右滑出按钮和上下滚列表，在 AppKit 眼里都是 `.scrollWheel` 事件，
/// 只能靠两个方向的位移量区分。判错的代价是实打实的：
/// 把竖滚当成横滑 → 滚动时蓝块跟着行跳；把横滑当成竖滚 → 蓝块冻在原地，松手才跳过去。
///
/// 阈值 1.2：真实触控板横滑时纵向总会带一点抖动，1:1 太容易被干扰；
/// 反过来两轴差不多大（斜着划）时保守算纵向——滚动比误判成滑动安全得多。
enum ScrollGestureAxis {
    static func isHorizontal(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        let dx = abs(deltaX)
        let dy = abs(deltaY)
        return dx > dy * 1.2 && dx > 0.4
    }
}
