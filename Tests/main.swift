import AppKit
import Foundation

// 轻量断言：失败退出码非零，方便接进 build.sh 或 CI。
var failures = 0

func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { print("FAIL  \(name)"); failures += 1 }
}

func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ name: String) {
    let ok = actual.map { $0 == expected } ?? false
    if ok {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)（期望 \(expected)，实际 \(actual.map { "\($0)" } ?? "nil")）")
        failures += 1
    }
}

// MARK: - cleanVersion：cask 版本号清洗
// 回归点：4.0.0-beta.1 不能被截成 4.0.0（否则 beta 被当成正式更新推出去）。

expectEqual(Cask.cleanVersion("1.2.3,456"), "1.2.3", "cleanVersion 逗号后缀截断")
expectEqual(Cask.cleanVersion("3.6.7-dbc92f97"), "3.6.7", "cleanVersion commit 后缀截断")
expectEqual(Cask.cleanVersion("4.0.0-beta.1"), "4.0.0-beta.1", "cleanVersion 保留 beta 后缀")
expectEqual(Cask.cleanVersion("2026.3.1"), "2026.3.1", "cleanVersion 普通版本原样")
expectEqual(Cask.cleanVersion(" 2.1.0 "), "2.1.0", "cleanVersion 去首尾空格")
expect(Cask.cleanVersion("v1.2") == nil, "cleanVersion 非数字开头拒绝")

// MARK: - isPrereleaseVersion

expect(isPrereleaseVersion("4.0.0-beta.1"), "beta.1 判为测试版")
expect(isPrereleaseVersion("1.2.3rc1"), "rc1 连写判为测试版")
expect(!isPrereleaseVersion("4.0.0"), "正式版不误判")
expect(!isPrereleaseVersion("2026.3.1"), "日期版本不误判")

// MARK: - Scanner.hasAppStoreReceipt：假收据识别
// 回归点：第三方直装版塞的 20 字节「收据」只有一行安装站网址，
// 不能当成商店包（否则被钉死在 iTunes 查询上，无检测源）。

private func makeApp(withReceipt data: Data?) -> String {
    let root = NSTemporaryDirectory()
        + "ur-receipt-\(UUID().uuidString)/Fake.app/Contents/_MASReceipt"
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    if let data {
        try! data.write(to: URL(fileURLWithPath: root + "/receipt"))
    }
    let contents = (root as NSString).deletingLastPathComponent
    return (contents as NSString).deletingLastPathComponent
}

let noReceipt = makeApp(withReceipt: nil)
expect(!Scanner.hasAppStoreReceipt(at: noReceipt), "没有收据：不算商店包")

let emptyReceipt = makeApp(withReceipt: Data())
expect(Scanner.hasAppStoreReceipt(at: emptyReceipt), "0 字节收据：仍按商店包算")

let fakeReceipt = makeApp(withReceipt: "https://macked.app/".data(using: .utf8))
expect(!Scanner.hasAppStoreReceipt(at: fakeReceipt), "20 字节网址收据：伪造，不算商店包")

let bigReceipt = makeApp(withReceipt: Data(count: 2048))
expect(Scanner.hasAppStoreReceipt(at: bigReceipt), "2KB 收据：算商店包")

let smallAppleReceipt = makeApp(withReceipt: Data(repeating: 0x20, count: 300)
    + "Apple Inc.".data(using: .utf8)!)
expect(Scanner.hasAppStoreReceipt(at: smallAppleReceipt), "小但带 Apple 签发串：算商店包")

// MARK: - Cask.bundleIds：从 uninstall 段提取 bundle id
// 回归点：.plist / .app 结尾的字符串不能混进来（trae-cn 的映射就是这么缺的）。

let traeObj: [String: Any] = [
    "artifacts": [
        ["uninstall": ["quit": ["cn.trae.app", "cn.trae.ShipIt"],
                       "delete": ["/Applications/Trae CN.app", "~/Library/Preferences/cn.trae.app.plist"]]]
    ]
]
let traeIds = Cask.bundleIds(in: traeObj)
expect(traeIds.contains("cn.trae.app"), "bundleIds 提取裸 id")
expect(traeIds.contains("cn.trae.shipit") || traeIds.contains("cn.trae.ShipIt"), "bundleIds 提取 ShipIt")
expect(!traeIds.contains("cn.trae.app.plist"), "bundleIds 过滤 .plist")
expect(!traeIds.contains("/applications/trae"), "bundleIds 不收路径")

let zapOnly: [String: Any] = ["artifacts": [["zap": ["trash": ["~/Library/x.y.z"]]]]]
expect(Cask.bundleIds(in: zapOnly).isEmpty, "zap/trash 段不参与提取")

// MARK: - PanelMetrics：10 行必须正好填满列表区

expect(PanelMetrics.topBarHeight + PanelMetrics.visibleRows * PanelMetrics.rowHeight
       + PanelMetrics.footerHeight == PanelMetrics.height,
       "10 行行高 + 顶部条 + 底栏 = 面板高（否则最后一行会被底栏压住或露出半行）")
expect(PanelMetrics.rowHeight == 46, "行高按当前面板尺寸应为 46")
expect(PanelMetrics.rowVerticalPadding * 2 + PanelMetrics.iconSide == PanelMetrics.rowHeight,
       "图标 + 上下留白 = 行高")

// MARK: - ScrollGestureAxis：横滑与纵向滚动的区分
// 回归点：把竖滚误判成横滑，蓝块会跟着行跳；把横滑误判成竖滚，蓝块冻在原地。

expect(ScrollGestureAxis.isHorizontal(deltaX: 40, deltaY: 0), "纯横向 → 算横滑")
expect(ScrollGestureAxis.isHorizontal(deltaX: -40, deltaY: 0), "左滑（负 dx）→ 算横滑")
expect(!ScrollGestureAxis.isHorizontal(deltaX: 0, deltaY: 40), "纯纵向 → 不算横滑")
expect(!ScrollGestureAxis.isHorizontal(deltaX: 3, deltaY: 40), "纵向为主、带横向抖动 → 不算横滑")
expect(ScrollGestureAxis.isHorizontal(deltaX: 40, deltaY: 3), "横滑为主、带竖向抖动 → 算横滑")
expect(!ScrollGestureAxis.isHorizontal(deltaX: 20, deltaY: 20), "两轴相等 → 保守算纵向")
expect(!ScrollGestureAxis.isHorizontal(deltaX: 0.3, deltaY: 0), "极小位移 → 不算横滑")

// MARK: - Scanner.displayName：面板里的名字 = Finder 里显示的名字
// 回归点 1：曾用 CFBundleDisplayName，出现 "Affinity for China"、"wpsoffice"、"Canva可画"。
// 回归点 2：改成直接取 .app 文件名后，Apple 的 "Compressor Creator Studio.app"
//           在面板里显示成 "Compressor Creator Studio"，而 Finder 里叫 "Compressor"。

expectEqual(Scanner.fileNameStem(of: "/Applications/Affinity.app"), "Affinity",
            "兜底：普通 app → 去掉 .app")
expectEqual(Scanner.fileNameStem(of: "/Applications/Comfy .app"), "Comfy",
            "兜底：文件名尾部带空格 → 裁掉空格")
expectEqual(Scanner.fileNameStem(of: "/Applications/Adobe Photoshop 2027/Adobe Photoshop 2027.app"),
            "Adobe Photoshop 2027", "兜底：厂商目录下的 app → 取自身文件名")
expectEqual(Scanner.fileNameStem(of: "/Applications/Douyin Webcast Mate.app/"), "Douyin Webcast Mate",
            "兜底：路径尾部带斜杠 → 仍能取到名字")

// 真实包校验：包名带 "Creator Studio" 的 Apple App，要显示成 Finder 里的短名
let compressor = "/Applications/Compressor Creator Studio.app"
if FileManager.default.fileExists(atPath: compressor) {
    expectEqual(Scanner.displayName(forPath: compressor), "Compressor",
                "Creator Studio 包 → 显示 Finder 名 Compressor（不是包名）")
}
let affinity = "/Applications/Affinity.app"
if FileManager.default.fileExists(atPath: affinity) {
    expectEqual(Scanner.displayName(forPath: affinity), "Affinity",
                "Affinity → 显示 Affinity（不是 CFBundleDisplayName 的 for China）")
}
// 回归点 3：豆包的中文名只在 zh_CN.lproj 里，displayName 会退回 "Doubao"
let doubao = "/Applications/Doubao.app"
if FileManager.default.fileExists(atPath: doubao) {
    expectEqual(Scanner.displayName(forPath: doubao), "豆包",
                "Doubao.app → 显示中文名 豆包")
}

// MARK: - Cask 映射表：换过产品线的 App 不许钉在老 cask 上
// 回归点：com.topazlabs.TopazGigapixel 曾被映射到已废弃的 topaz-gigapixel-ai（8.4.4），
// 结果装了 1.5.0 的用户永远看到「可更新 → 8.4.4」。

expectEqual(Cask.vendorPrefix("com.topazlabs.Topaz-Video"), "com.topazlabs",
            "厂商前缀：取前两段")
expectEqual(Cask.vendorPrefix("com.google.GeminiMacOS"), "com.google", "厂商前缀：Google")
expect(Cask.vendorPrefix("com.tdesktop.Telegram") != Cask.vendorPrefix("ru.keepcoder.Telegram"),
       "厂商前缀不同 → 同名不同 App 仍会被挡下")

let mapPath = "Resources/cask-map.json"
if let data = FileManager.default.contents(atPath: mapPath),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let bundles = obj["bundles"] as? [String: String] {
    expectEqual(bundles["com.topazlabs.TopazGigapixel"], "topaz-gigapixel",
                "Topaz Gigapixel → 新版 cask（不是废弃的 -ai）")
    expectEqual(bundles["com.topazlabs.TopazPhoto"], "topaz-photo",
                "Topaz Photo → 新版 cask（不是废弃的 -ai）")
    expectEqual(bundles["com.google.GeminiMacOS"], "google-gemini", "Gemini → google-gemini")
    expectEqual(bundles["com.netease.uuremote"], "uuremote", "UU远程 → uuremote")
    // 回归点：Telegram 有两套，两个 cask 的 .app 都叫 Telegram.app。
    // 自动取舍按 token 字母序把 Telegram Desktop（7.x）钉到了原生版（13.x）上，
    // 结果本机装了 7.4.4 却一直显示「无检测源」。
    expectEqual(bundles["com.tdesktop.Telegram"], "telegram-desktop",
                "Telegram Desktop → telegram-desktop（不是原生版 telegram）")
    expectEqual(bundles["ru.keepcoder.Telegram"], "telegram", "原生版 Telegram 仍归 telegram")
} else {
    print("SKIP  找不到 \(mapPath)（不在仓库根目录跑？）")
}

// MARK: - electron-updater：app-update.yml → 候选地址
// 回归点：Electron 包没有 SUFeedURL，全靠包内这份 yml 找出官方版本号。
// 这里钉住几种真实形态（Motrix / Notion / 洛雪 / Trae / 光鸭云盘）。

expectEqual(ElectronUpdater.feed(config: "provider: generic\nurl: https://dl.motrix.app/releases/\n")?.candidates,
            ["https://dl.motrix.app/releases/latest-mac.yml"], "generic：补 /latest-mac.yml，尾斜杠不叠加")

let notionYML = "provider: generic\nurl: 'https://desktop-release.notion-static.com'\nchannel: arm64\n"
expectEqual(ElectronUpdater.feed(config: notionYML)?.candidates,
            ["https://desktop-release.notion-static.com/latest-mac.yml",
             "https://desktop-release.notion-static.com/arm64-mac.yml"],
            "latest 优先、channel 兜底（Notion 没有 arm64-mac.yml，先试它会白等超时）")
expectEqual(ElectronUpdater.feed(config: "provider: generic\nurl: 'https://x.dev/a'\n")?.candidates,
            ["https://x.dev/a/latest-mac.yml"], "单引号 url 去掉引号")

let githubYML = "owner: lyswhut\nrepo: lx-music-desktop\nprovider: github\nupdaterCacheDirName: lx-music-desktop-updater\n"
expectEqual(ElectronUpdater.feed(config: githubYML)?.githubRepo, "lyswhut/lx-music-desktop",
            "github 型：只用 owner/repo，不走 yml")
expect(ElectronUpdater.feed(config: githubYML)?.candidates.isEmpty ?? false, "github 型不生成 yml 候选")

expect(ElectronUpdater.feed(config: "provider: custom\nurl: ''") == nil, "custom 型（Trae CN）没有可用地址")
expect(ElectronUpdater.feed(config: "provider: generic\nurl: ''\n") == nil, "url 为空 → 当作没有这个源")
expect(ElectronUpdater.feed(config: "provider: generic\nurl: https://updates.invalid/pc\n") == nil,
       "占位域名 updates.invalid（光鸭云盘）→ 不建必然失败的通道")
expect(ElectronUpdater.feed(config: "provider: generic\n") == nil, "没有 url 键")

// MARK: - latest-mac.yml：版本号与安装包

let canvaYML = """
version: 1.129.0
files:
  - url: Canva-1.129.0-cn-universal-mac.zip
    sha512: H08wXrmC4+8kXmk4vT6b4GogcVd0YF79BReYdEnofEWuV+ZytIplmQi8JIf3kZH2Xmzt7dSrvnONpgmCFgGitw==
    size: 225677977
  - url: Canva-1.129.0-cn-universal.dmg
releaseDate: '2026-11-19T08:12:03.412Z'
"""
expectEqual(ElectronUpdater.parse(latestMacYML: canvaYML)?.version, "1.129.0", "取顶格 version")
expectEqual(ElectronUpdater.parse(latestMacYML: canvaYML)?.fileName, "Canva-1.129.0-cn-universal.dmg",
            "安装包优先取 .dmg（不是 zip）")
expect(ElectronUpdater.parse(latestMacYML: canvaYML)?.releaseDate != nil, "releaseDate 带毫秒也能解")

// 幕布那种：地址失效后站点用 200 回一张 404 网页
expect(ElectronUpdater.parse(latestMacYML: "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n") == nil,
       "HTML 页面不当作更新清单")

// 缩进里的 version 不能被认成顶层版本号
let nestedYML = "files:\n  - version: 9.9.9\nversion: 1.0.0\n"
expectEqual(ElectronUpdater.parse(latestMacYML: nestedYML)?.version, "1.0.0", "只认顶格 version")

expectEqual(ElectronUpdater.parse(latestMacYML: "version: \"7.44.1\"\n")?.version, "7.44.1",
            "带引号的版本号去引号")

// MARK: - electron 清单可信度
// 回归点：抖音直播伴侣包内的 app-update.yml 指向 tron-demo 通用更新服务，
// 那份 yml 写的是 1.0.2，App 本身 10.0.5 —— 主版本号脱节就当这份源不可信。

expect(Checker.plausible("1.129.0", vs: "1.129.0"), "同版本可信")
expect(Checker.plausible("2.0.0", vs: "1.9.0"), "跨一个大版本仍可信")
expect(!Checker.plausible("1.0.2", vs: "10.0.5"), "主版本号脱节（抖音直播伴侣）→ 不可信")
expect(Checker.plausible("2026.2.4", vs: "2026.2.3"), "日期式版本号照常比")
expect(Checker.plausible("abc", vs: "1.0"), "解析不出主版本号时不拦")

// MARK: - 排序：名称 / 最近使用 / 安装时间
// 回归点：早先有四档（多出 A→Z / Z→A），用户要求只留这三档。

expectEqual(SortMode.allCases.map(\.rawValue), ["name", "recent", "installed"],
            "三个选项，顺序就是菜单顺序")
expectEqual(SortMode.allCases.map(\.title), ["名称", "最近使用", "安装时间"], "菜单文案")
expect(SortMode(rawValue: "az") == nil, "已删掉的旧值解析为 nil，不会崩")

// 旧 state.json 里还可能存着 "az" / "za"：解出来要安静落到「名称」
var legacy = AppSettings()
legacy.sortOrder = "za"
let oldSort = try! JSONDecoder().decode(AppSettings.self,
                                        from: try! JSONEncoder().encode(legacy))
expectEqual(oldSort.sort, .name, "旧值 za → 回落到名称")
expectEqual(AppSettings().sort, .name, "没存过排序 → 默认名称")

// 「最近使用」时间来自 Spotlight。显示名和它是一次查询取出来的，别把名字带偏。
if FileManager.default.fileExists(atPath: compressor) {
    expectEqual(Scanner.spotlightInfo(compressor).name, "Compressor",
                "合并查询（名字 + 最近使用）仍取到 Finder 名")
}
expect(Scanner.lastUsedMap(paths: ["/Applications/一定不存在的 App.app"]).isEmpty,
       "Spotlight 查不到日期 → 不进结果，排序时自然落到末尾")
let sentryPath = "/Applications/Sentry.app"
if FileManager.default.fileExists(atPath: sentryPath) {
    expect(Scanner.lastUsedMap(paths: [sentryPath])[sentryPath] != nil,
           "刚启动过的 App 能查到最近使用时间")
}

// MARK: - 外观：自动 / 浅色 / 深色
// 回归点：外观要跟着系统默认走（Apple 的常规做法），手动指定的值要能存能解；
// 旧 state.json 没有这个键、或者存着以后删掉的值，都得安静落到「自动」。

expectEqual(AppAppearance.allCases.map(\.rawValue), ["system", "light", "dark"],
            "三个选项，顺序就是分段控件的顺序")
expectEqual(AppAppearance.allCases.map(\.title), ["自动", "浅色", "深色"], "分段控件文案")
expect(AppAppearance(rawValue: "system")?.nsAppearance == nil,
       "自动 = 不设 NSApp.appearance，交回系统")
expectEqual(AppAppearance(rawValue: "dark")?.nsAppearance?.name, .darkAqua, "深色 → darkAqua")
expectEqual(AppAppearance(rawValue: "light")?.nsAppearance?.name, .aqua, "浅色 → aqua")

expectEqual(AppSettings().appearanceMode, .system, "没存过外观 → 默认自动")

var darkSettings = AppSettings()
darkSettings.appearance = "dark"
let decodedDark = try! JSONDecoder().decode(AppSettings.self,
                                           from: try! JSONEncoder().encode(darkSettings))
expectEqual(decodedDark.appearanceMode, .dark, "存过的深色能存能解")

var bogusSettings = AppSettings()
bogusSettings.appearance = "sepia"   // 将来改了枚举，老配置不能把整份设置带崩
let decodedBogus = try! JSONDecoder().decode(AppSettings.self,
                                            from: try! JSONEncoder().encode(bogusSettings))
expectEqual(decodedBogus.appearanceMode, .system, "不认识的外观值 → 回落到自动")

// MARK: - 厂商规则：MindNode 发布说明页 / PastePal 的已知 appcast
// 两个都是「包内查不到更新源」的典型：SUFeedURL 空、官网 appcast 失效。
// MindNode 只能从发布说明页的时间轴取版本号。

let mindNodeHTML = """
<li id="2026.7.2" class="releasesTimeline__release "><h2 class="releasesTimeline__version"><time dateTime="2026-11-10">2026.7.2</time></h2>
<li id="2026.7.1" class="releasesTimeline__release "><h2 class="releasesTimeline__version"><time dateTime="2026-10-28">2026.7.1</time></h2>
<li id="2026.6.2" class="releasesTimeline__release "><h2 class="releasesTimeline__version"><time dateTime="2026-09-30">2026.6.2</time></h2>
"""
expectEqual(Rules.mindNodeVersion(in: mindNodeHTML), "2026.7.2", "取时间轴里最大的版本号")
expect(Rules.mindNodeVersion(in: "<html><body>404 Page not found</body></html>") == nil,
       "页面上没有版本号 → nil，交给下一层，别瞎猜")
expectEqual(Rules.mindNodeVersion(in: #"<h2 class="releasesTimeline__version"><time>2026.10</time></h2>"#),
            "2026.10", "两位数月份照常比大小")

// PastePal 的 feed 写在 SparkleService 代码里，Info.plist 没有 SUFeedURL
expectEqual(KnownAppcasts.feed(forBundleId: "com.onmyway133.PastePal"),
            "https://raw.githubusercontent.com/onmyway133/archives/master/PastePal.xml",
            "PastePal 用已知 appcast 补位")
expect(KnownAppcasts.feed(forBundleId: "com.example.nothing") == nil,
       "表里没有的 bundle id 不给地址")
expect(KnownAppcasts.feed(forBundleId: nil) == nil, "没有 bundle id 也不崩")

// MARK: - 商店兜底：不是商店装的，但商店里也有同一个 App
// 回归点：PastePal 的 appcast 挂在 raw.githubusercontent.com 上，国内时不时 TLS 失败，
// 一失败整条就变「检测失败」。商店里也有 PastePal（bundle id 相同），可以拿来兜一层。
// 但商店版落后（2.17.0 / 独立版 2.22.4），所以它只能当兜底、不能抢第一顺位。

expect(KnownAppStore.mode(forBundleId: "com.ideasoncanvas.mindnode") == .preferred,
       "MindNode：商店版和独立版同一套 2026.x 编号 → 商店优先")
expect(KnownAppStore.mode(forBundleId: "com.onmyway133.PastePal") == .fallback,
       "PastePal：商店版落后于独立版 → 只当兜底")
// Telegram 的 com.tdesktop.Telegram 不在 App Store（cn/us/jp 三个区 lookup 都是 0 条），
// 商店里的 Telegram 是另一款产品（ru.keepcoder.Telegram 原生版 13.x），不能拿来比。
expect(KnownAppStore.mode(forBundleId: "com.tdesktop.Telegram") == nil,
       "Telegram Desktop：商店里没有这个包，不接商店")
expect(KnownAppStore.mode(forBundleId: nil) == nil, "没有 bundle id 也不崩")

let pastePalStore = Checker.StoreRecord(version: "2.17.0", page: "https://apps.apple.com/cn/app/id1503446680",
                                        seller: "https://pastepal.app", release: nil, notes: nil,
                                        isMacRecord: true)
let behind = Checker.storeFallbackOutcome(pastePalStore, current: "2.22.4", build: "245", allowBeta: false)
expectEqual(behind.status, CheckStatus.upToDate, "商店版比本机旧 → 已是最新（不报假更新）")
expect(behind.note?.hasPrefix("App Store 上的是 2.17.0") == true, "说明商店版落后，别让人以为漏了更新")

let sameStore = Checker.StoreRecord(version: "2026.7.2", page: nil, seller: nil, release: nil, notes: nil,
                                    isMacRecord: true)
expectEqual(Checker.storeFallbackOutcome(sameStore, current: "2026.7.2", build: "632", allowBeta: false).status,
            CheckStatus.upToDate, "版本相同 → 已是最新")

let newerStore = Checker.StoreRecord(version: "2.23.0", page: nil, seller: nil, release: nil, notes: nil,
                                     isMacRecord: true)
let newer = Checker.storeFallbackOutcome(newerStore, current: "2.22.4", build: "245", allowBeta: false)
expectEqual(newer.status, CheckStatus.updateAvailable, "商店版更新 → 提示更新")
expect(newer.note?.hasPrefix("版本号来自 App Store") == true, "说清版本号是从商店拿的")

let betaStore = Checker.StoreRecord(version: "3.0.0-beta.1", page: nil, seller: nil, release: nil, notes: nil,
                                    isMacRecord: true)
let suppressed = Checker.storeFallbackOutcome(betaStore, current: "2.22.4", build: "245", allowBeta: false)
expectEqual(suppressed.status, CheckStatus.upToDate, "默认只跟正式版比：商店里是 beta 就不提示")
expect(suppressed.suppressedBeta, "压下去时打标记，切开关时能重查")

// 编号体系差太远（换过产品线、或商店里那条是别的商品）：宁可不给源，也别报假更新
expect(!Checker.plausible("13.1.0", vs: "7.4.4"), "商店里另一款产品的版本号（Telegram 原生版 13.x）→ 不可信")

// MARK: - 版本号尾巴上的括号构建号（Dia）
// 回归点：Dia 的 appcast 写的是 shortVersionString="1.58.0 (91297)"，本机是 1.58.0。
// 整串拿去比就是「1.58.0 (91297) 比 1.58.0 新」，装到最新了还天天挂一个「可更新」。

let dia = splitTrailingBuild("1.58.0 (91297)")
expectEqual(dia.version, "1.58.0", "括号构建号拆出去，版本号只留 1.58.0")
expectEqual(dia.build, "91297", "括号里那串当构建号")
expectEqual(splitTrailingBuild("1.58.0（91297）").version, "1.58.0", "全角括号一样拆")
expectEqual(splitTrailingBuild("1.58.0").build, nil, "没有括号 → 没有构建号")
expectEqual(splitTrailingBuild("2.0 (Beta)").version, "2.0 (Beta)", "括号里是文字标签（Beta）→ 原样保留")
expectEqual(splitTrailingBuild("1.0 (Universal)").build, nil, "括号里是 Universal → 不算构建号")
expectEqual(splitTrailingBuild(" (91297)").build, nil, "只有括号没有版本号 → 不当版本号拆")

expect(Ver.isNewer("1.58.0 (91297)", than: "1.58.0"), "没拆之前确实会误判成更新（这就是那个 bug）")
expect(!Ver.isNewer(dia.version, than: "1.58.0"), "拆完之后 1.58.0 对 1.58.0 就是同一个版本")
expect(sameBuild("91297", "91297"), "源里的构建号跟本机一致 → 装的就是这个包")
expect(!sameBuild("91298", "91297"), "构建号不同 → 不是同一个包")
expect(!sameBuild(nil, "91297"), "源里没给构建号 → 不比")

// 真喂一段 Dia 的 appcast，解析出来要能直接用于比较
let diaXML = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>New Version Available</title>
      <version xmlns="http://www.andymatuschak.org/xml-namespaces/sparkle">91297</version>
      <shortVersionString xmlns="http://www.andymatuschak.org/xml-namespaces/sparkle">1.58.0 (91297)</shortVersionString>
      <enclosure url="https://releases.diabrowser.com/release/Dia-1.58.0-91297.zip"
        sparkle:version="91297" sparkle:shortVersionString="1.58.0 (91297)" length="1" type="application/octet-stream"/>
      <deltas xmlns="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <enclosure url="https://releases.diabrowser.com/release/Dia-from-90935-to-91297.delta"
          sparkle:deltaFrom="90935" length="1" type="application/octet-stream"/>
        <enclosure url="https://releases.diabrowser.com/release/Dia-from-90792-to-91297.delta"
          sparkle:deltaFrom="90792" length="1" type="application/octet-stream"/>
      </deltas>
    </item>
  </channel>
</rss>
"""
let diaItems = AppcastParser().parse(Data(diaXML.utf8))
expectEqual(diaItems.first?.marketingVersion, "1.58.0", "解析出的营销版本号不含括号构建号")
expectEqual(diaItems.first?.marketingBuild, "91297", "括号里的构建号单独留着")
expectEqual(diaItems.first?.buildVersion, "91297", "sparkle:version 仍是构建号")
// 回归点：<deltas> 里的增量包也挂在 enclosure 上、还排在后面，以前会把完整包覆盖掉，
// Dia 的「更新」点下去下一个 .delta（差分补丁，单独装不上）。
expect(diaItems.first?.enclosure?.hasSuffix(".zip") == true,
       "下载地址取完整包（.zip），不被后面的 .delta 增量包覆盖")

// MARK: - beta 通道 / 版本号必须能被认出来（2026-11-23「关了开关还报测试版」）
// MacMix 的 appcast 首条是 beta：既有 <sparkle:channel>beta</sparkle:channel>，
// shortVersionString 也写着 "2.3.8 Beta 1"。两个信号都得能识别，
// 否则 allowBeta=false 时 sparkle() 会把它当正式版推出去。
let betaXML = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>MacMix 2.3.8 Beta 1</title>
      <sparkle:version>35</sparkle:version>
      <sparkle:shortVersionString>2.3.8 Beta 1</sparkle:shortVersionString>
      <sparkle:channel>beta</sparkle:channel>
      <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/ljmng7/MacMix/releases/download/v2.3.8-beta.1/MacMix-beta.dmg"
        sparkle:version="35" length="1" type="application/octet-stream"/>
    </item>
    <item>
      <title>MacMix 2.3.7</title>
      <sparkle:version>34</sparkle:version>
      <sparkle:shortVersionString>2.3.7</sparkle:shortVersionString>
      <enclosure url="https://github.com/ljmng7/MacMix/releases/download/v2.3.7/MacMix.dmg"
        sparkle:version="34" length="1" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""
let betaItems = AppcastParser().parse(Data(betaXML.utf8))
expectEqual(betaItems.count, 2, "MacMix appcast 解析出两条")
expectEqual(betaItems.first?.channel, "beta", "beta 通道标记被读到")
expectEqual(betaItems.first?.marketingVersion, "2.3.8 Beta 1", "beta 版本号完整保留（没被当成构建号拆掉）")
expect(isPrereleaseVersion(betaItems.first?.marketingVersion ?? ""), "2.3.8 Beta 1 判为测试版")
expect(!isPrereleaseVersion(betaItems[1].marketingVersion ?? ""), "2.3.7 正式版不误判")

// MARK: -

if failures > 0 {
    print("\n\(failures) 个用例失败")
    exit(1)
}
print("\n全部通过")
