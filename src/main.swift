import AppKit
import Combine
import SwiftUI

/// 面板窗口。无边框窗口默认当不了 key window，方向键 / Return 就收不到，所以放开。
final class PanelWindow: NSPanel {
    var fixedSize: NSSize?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let fixedSize { rect.size = fixedSize }
        super.setFrame(rect, display: flag)
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(fixedSize ?? size)
    }
}

/// 菜单栏图标的三种取法：完整静态图，或扫描动画拆出的箭头层 / 环+点层。
enum StatusIconPart {
    case full, arrow, ringDots
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow?
    private var panelHost: NSView?
    private let service = UpdateService()
    private let updater = SelfUpdater()
    private let ui = UIState()
    private var cancellable: AnyCancellable?
    private var bobCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    /// 外观（跟随系统 / 浅色 / 深色）：设置里改一次，整个应用跟着换
    private var appearanceCancellable: AnyCancellable?
    private var selfCheckScheduler: NSBackgroundActivityScheduler?
    /// 面板开着时的键盘监听（↑↓ / Return）；只有面板是 key window 才接管
    private var keyMonitor: Any?
    /// 面板开着时的全局鼠标监听：点别的 App 的任何地方都收掉面板
    private var outsideClickMonitor: Any?
    /// 菜单栏图标在屏幕上的范围（弹出面板时缓存）。点它时既要弹面板又要能收面板，
    /// 所以「点图标」不能被当成「点别处」：应用失活、全局点击两条收起路径都要放行。
    private var statusItemRect: NSRect = .zero

    // 扫描时：箭头那层不动，「开口环 + 三个点」整层绕中心转（加载效果）。
    // 缺口和点一起转，点始终待在缺口里，不会转到环上融进去。
    private var scanAnimating = false
    private var arrowLayer: CALayer?
    private var ringLayer: CALayer?
    private static let spinPeriod: CFTimeInterval = 1.1    // 转一圈

    private let panelSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height)
    /// NSPopover 的 contentSize 就是整块玻璃的大小，内容直接铺满；
    /// 自建面板也照这个来，窗口 = 内容 364×548，不能额外留内边距，
    /// 否则面板会整体变大、控件相对边缘的位置全被推到里面去。
    private let panelPadding: CGFloat = 0
    private var panelWindowSize: NSSize {
        NSSize(width: panelSize.width + panelPadding * 2, height: panelSize.height + panelPadding * 2)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick(_:))
            // 左右键都发同一个 action：点一下图标就是「开/关面板」
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildMainMenu()
        buildPanel()

        // 调试用：SENTRY_SHOW_PANEL=1 时启动就把面板摆出来，方便截图核对排版；
        // =2 直接摆成顶栏搜索态，=3 摆面板并翻到设置页。正常启动没有这个开关，行为完全不变。
        // （写成一个变量带多个值，是因为 open 只认一个 --env，给两个变量第二个会整个丢掉。）
        if let demo = debugValue("SENTRY_SHOW_PANEL"), demo != "0" {
            // 配合 SENTRY_PANEL_TAB=1 可以直接摆到「其他」页，方便截图核对
            if let tab = debugValue("SENTRY_PANEL_TAB"), let n = Int(tab) {
                ui.tab = n
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.showPanel()
                if demo == "2" { self?.ui.searchActive = true }
                // 再等一拍：面板刚弹出来时 SwiftUI 还在建视图，这时翻页会被吃掉
                if demo == "3" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.showSettings() }
                }
            }
        }

        // 调试用：SENTRY_SCAN_NOW=1 时启动就强制全量重扫。
        // 正常启动只在结果过期（设置里的间隔小时数）时才查，验证新检测源时等不起。
        if debugValue("SENTRY_SCAN_NOW") == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.service.checkAll(force: true)
            }
        }

        // 调试用：UR_SCROLL_TEST=1 时面板弹出来后自己把列表滚一遍，量滚动掉帧。
        // 用外部合成滚轮事件驱动面板很容易被真实点击打断，让 App 自己滚自己的
        // 列表最稳：同一套 SwiftUI 布局、同一套 List，量到的就是用户滚时的开销。
        if debugValue("UR_SCROLL_TEST") == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runScrollTest()
            }
        }

        // 调试用：SENTRY_TEST_NOTIFY=1 时启动 3 秒后发一条测试通知，
        // 排查「开关开着但收不到」到底是授权、投递还是展示的问题。
        if debugValue("SENTRY_TEST_NOTIFY") == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Notifier.shared.post(title: "Sentry 测试通知",
                                     body: "能看到这条，说明通知链路是通的。",
                                     id: "sentry.test.\(Int(Date().timeIntervalSince1970))")
            }
        }

        // 首次安装先看引导：通知授权放在引导里，不让系统授权框抢在欢迎窗口前面弹出来
        if OnboardingWindow.isNeeded {
            Notifier.shared.prepare()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                OnboardingWindow.presentIfNeeded()
            }
        } else {
            Notifier.shared.setup()
        }
        Notifier.shared.onOpen = { [weak self] appId in
            self?.showPanel()
            // 面板弹出来以后再让列表定位，不然 SwiftUI 还没渲染完，scrollTo 会落空
            if let appId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(name: .urRevealRow, object: appId)
                }
            }
        }

        // 扫描时菜单栏图标的三个点沿环转，扫完停回原样
        bobCancellable = service.$checking
            .receive(on: RunLoop.main)
            .sink { [weak self] checking in
                Task { @MainActor in
                    if checking { self?.startScanAnimation() } else { self?.stopScanAnimation() }
                }
            }

        // 后台查完就刷新角标/图标，不用等用户点一下
        cancellable = service.$updateCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }

        // 设置窗口里关掉「在菜单栏显示更新数量」时，这里立刻把角标收掉
        settingsCancellable = service.$settings
            .map(\.countVisible)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }

        // 外观：跟随系统 / 浅色 / 深色。设置一变就落到 NSApp.appearance 上；
        // 启动时 bootstrap 载入完 state.json 也会再发一次，所以不用额外写「启动时应用」。
        appearanceCancellable = service.$settings
            .map(\.appearanceMode)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { mode in
                Task { @MainActor in AppAppearance.apply(mode) }
            }

        updateBadge()
        service.bootstrap()

        // 本软件自己的更新：启动静默查一次，之后每 24 小时查一次（设置面板里也有手动按钮）
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.updater.checkIfStale()
        }
        // 同样交给 NSBackgroundActivityScheduler：24 小时是大周期，
        // 更需要系统根据睡眠/电量来挑时间，而不是开机时挂一个死循环 Timer。
        let selfCheck = NSBackgroundActivityScheduler(identifier: "com.hushixiong.sentry.selfcheck")
        selfCheck.repeats = true
        selfCheck.interval = 24 * 3600
        selfCheck.tolerance = 2 * 3600
        selfCheck.qualityOfService = .utility
        selfCheck.schedule { [weak self] completion in
            Task { @MainActor in self?.updater.check() }
            completion(.finished)
        }
        selfCheckScheduler = selfCheck
    }

    /// 从系统设置切回来时重读一次通知权限：用户很可能刚在那边点了「允许通知」，
    /// 不刷的话设置页还停在「已在系统设置中关闭」，开关也还是「去允许」。
    func applicationDidBecomeActive(_ notification: Notification) {
        Notifier.shared.refreshAuthorization()
    }

    /// 调试开关的取值：先看环境变量，再看 UserDefaults。
    /// `open --env` 在新系统上时不时失效（LaunchServices 把请求当成「激活已有实例」，变量整个丢掉），
    /// 所以留一条 `defaults write com.hushixiong.sentry SENTRY_SHOW_PANEL 3` 的路子。
    private func debugValue(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        return UserDefaults.standard.string(forKey: key)
    }

    // MARK: - 面板

    /// 参考 status-trio 的做法：不用 NSPopover，自己开一个无边框 NSPanel，
    /// 背景交给系统玻璃视图。这样就没有顶部的小三角，材质、圆角、阴影仍然是系统的。
    private func buildPanel() {
        let win = PanelWindow(contentRect: NSRect(origin: .zero, size: panelWindowSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        win.isFloatingPanel = true
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.becomesKeyOnlyIfNeeded = false
        win.animationBehavior = .none
        win.fixedSize = panelWindowSize

        let controller = NSHostingController(rootView: ContentView(service: service, ui: ui,
                                                                   updater: updater,
                                                                   onQuit: {
                                                                       NSApp.terminate(nil)
                                                                   }))
        let hostView = controller.view
        hostView.frame = NSRect(x: panelPadding, y: panelPadding,
                                width: panelSize.width, height: panelSize.height)
        hostView.translatesAutoresizingMaskIntoConstraints = true

        // 最外层容器负责圆角裁切：窗口的阴影是照着内容的轮廓画的，
        // 只让玻璃自己圆角的话，四角会露出一圈窗口阴影，看上去就是几条黑边
        let container = NSView(frame: NSRect(origin: .zero, size: panelWindowSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.style = .regular
            glass.cornerRadius = 16
            glass.autoresizingMask = [.width, .height]
            // 关键：中间隔一层普通容器。hosting view 直接塞进 glass.contentView，
            // 它会按自己的固有尺寸反向撑坏窗口和玻璃的分层渲染
            let glassHost = NSView(frame: glass.bounds)
            glassHost.autoresizingMask = [.width, .height]
            glassHost.addSubview(hostView)
            glass.contentView = glassHost
            container.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(hostView)
            container.addSubview(effect)
        }

        win.contentView = container

        panelHost = hostView
        panel = win
    }

    // MARK: - 设置

    /// 设置不再单开窗口：不显示的先把面板弹出来，再把内容翻到设置页。
    private func showSettings() {
        if panel?.isVisible != true { showPanel() }
        // 面板刚弹出时 SwiftUI 还没建好视图，等一拍再翻页，动画才看得见
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.ui.showSettings = true
        }
    }

    /// 一句极简主菜单：只是为了让 ⌘, 和 ⌘Q 有地方挂。
    /// 菜单栏本身不显示（LSUIElement / .accessory），键等价物照样生效。
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let close = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(close)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Sentry", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单：文本编辑快捷键必须有菜单项挂载，否则 LSUIElement 应用里
        // ⌘C / ⌘V / ⌘A 在搜索框里全部失效。target 留空，走响应链找第一响应者。
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: NSSelectorFromString("delete:"), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "搜索", action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        editMenu.addItem(find)
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let rescanItem = NSMenuItem(title: "重新扫描", action: #selector(rescanFromMenu), keyEquivalent: "r")
        rescanItem.target = self
        viewMenu.addItem(rescanItem)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    /// ⌘F：面板没开就先弹出来，再把焦点交给搜索框
    @objc private func focusSearch() {
        if panel?.isVisible != true { showPanel() }
        // 顶栏平时是「排序 / 搜索」两颗按钮，输入框不在视图树里 —— 先把搜索态打开
        ui.searchActive = true
        // 面板刚弹出时 SwiftUI 还没把搜索框建出来，等一拍再发
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .updateRadarFocusSearch, object: nil)
        }
    }

    @objc private func rescanFromMenu() { service.rescan() }

    private func showPanel() {
        guard let panel, !panel.isVisible else { return }
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // 应用不是活跃状态时 makeKeyAndOrderFront 不一定能拿到 key，
        // 单独再要一次，方向键、悬停反馈才有反应
        panel.makeKey()
        installPanelKeyMonitor()
        installOutsideClickMonitor()
        // 排序方式是「最近使用」时补刷一下时间：这东西跟着用户开 App 一直在变，
        // 只在扫描那一刻取一次的话，开一会儿顺序就不对了（内部有限流，60 秒最多一次）
        service.refreshLastUsed()
    }

    /// 贴着菜单栏图标下沿 6pt、水平居中，左右夹在屏幕可见区域内
    private func positionPanel() {
        guard let panel, let button = statusItem.button, let buttonWindow = button.window else { return }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // 放宽一圈：点到图标边缘的间隙也算「点图标」
        statusItemRect = rect.insetBy(dx: -8, dy: -10)
        let size = panelWindowSize
        var x = rect.midX - size.width / 2
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: rect.minY - size.height - 6))
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        // 面板关掉就回到列表页：下次点开应该先看到更新，而不是停在设置里
        removePanelKeyMonitor()
        removeOutsideClickMonitor()
        // 关掉就回列表页：设置和关于都复位，否则下次点开还停在关于页
        ui.showSettings = false
        ui.showAbout = false
        ui.aboutFromSettings = false
        // 搜索态也复位：下次点开先看到「排序 / 搜索」两颗按钮，而不是停在输入框上。
        // 不动的只有 query：列表还是上次筛过的（放大镜染色提示），点一下还能接着改。
        ui.searchActive = false
        updateBadge()
    }

    // MARK: - 调试：自动滚动量帧

    private var scrollTestTimer: Timer?

    /// 依次把面板里每个 List 用 60Hz 合成滚轮滚 1.8 秒，量滚动掉帧。
    /// 用 NSScrollView.scrollWheel 走真实滚动通路（clipView.scroll(to:) 对
    /// ListCore 的虚拟化文档高度无效，只会滚几十像素）。
    ///
    /// 帧耗时口径跟人工测的一致：60Hz Timer 相邻两次 tick 的实际间隔就是主线程的
    /// 一帧（Timer 被主线程的活拖慢多少，间隔就多长）。每 0.5s 汇总一次
    /// 「窗口内最长单帧 + >20ms 的掉帧次数」，整轮结束再报一次全局最长单帧。
    private func runScrollTest() {
        guard let panel, panel.isVisible else { writeScrollTest("panel-not-visible"); return }
        // 每轮重测都从头记
        try? FileManager.default.removeItem(atPath: "/tmp/scrolltest.log")
        var views: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView { views.append(sv) }
            for sub in v.subviews { walk(sub) }
        }
        if let cv = panel.contentView { walk(cv) }
        guard !views.isEmpty else { writeScrollTest("no-scrollview"); return }

        var index = 0
        var elapsed: TimeInterval = 0
        var markPending = true
        writeScrollTest("lists=" + views.map { String(Int($0.documentView?.bounds.height ?? -1)) }.joined(separator: ","))

        // 帧耗时统计
        var lastTick = CACurrentMediaTime()
        var winStart = lastTick
        var winMax = 0.0
        var winDrops = 0
        var winFrames = 0
        var globalMax = 0.0
        var globalDrops = 0

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }

                // 先量上一帧到现在过了多久（这就是主线程这一帧的耗时）
                let now = CACurrentMediaTime()
                let gap = now - lastTick
                lastTick = now
                winMax = max(winMax, gap)
                winFrames += 1
                globalMax = max(globalMax, gap)
                if gap > 0.020 { winDrops += 1; globalDrops += 1 }
                if now - winStart >= 0.5 {
                    self.writeScrollTest(String(format: "win list%d frames=%d max=%.0fms drops=%d",
                                                min(index, views.count - 1), winFrames, winMax * 1000, winDrops))
                    winStart = now; winMax = 0; winDrops = 0; winFrames = 0
                }

                if index >= views.count {
                    timer.invalidate()
                    self.scrollTestTimer = nil
                    self.writeScrollTest(String(format: "end globalMax=%.0fms globalDrops=%d", globalMax * 1000, globalDrops))
                    // 量完自己收起面板并退出，不留在屏幕上打扰人
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.hidePanel()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        NSApp.terminate(nil)
                    }
                    return
                }
                let sv = views[index]
                if markPending {
                    markPending = false
                    self.writeScrollTest("list\(index) start doc=\(Int(sv.documentView?.bounds.height ?? -1)) y=\(Int(sv.contentView.bounds.origin.y))")
                }
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0),
                   let ev = NSEvent(cgEvent: cg) {
                    sv.scrollWheel(with: ev)
                }
                elapsed += 1.0 / 60.0
                if elapsed >= 1.8 {
                    self.writeScrollTest("list\(index) end doc=\(Int(sv.documentView?.bounds.height ?? -1)) y=\(Int(sv.contentView.bounds.origin.y))")
                    index += 1
                    elapsed = 0
                    markPending = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTestTimer = timer
    }

    private func writeScrollTest(_ s: String) {
        // 追加写：一轮测试要留多行（每 0.5s 一行 + 首尾），覆盖写就只剩最后一行
        let line = "scrolltest \(s)\n"
        let path = "/tmp/scrolltest.log"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - 面板键盘

    /// 只挂本地监视器：面板是 key window 时接管 ↑↓ / Return / Esc，其它情况原样放行。
    private func installPanelKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 只把 keyCode 带进主线程，NSEvent 本身不是 Sendable
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { self.handlePanelKey(code: code) }
            return handled ? nil : event
        }
    }

    private func removePanelKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 面板是开着的时候，点「别的 App」的任何地方（别人的窗口、桌面、Dock、菜单栏图标）都收掉。
    /// 全局监视器只收到发给别的进程的事件，所以点面板本身、点设置/关于窗口都不会把自己关掉 ——
    /// 正好是「点任何地方都关，除了本软件窗口」。
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 点的是自己的菜单栏图标：交给 handleClick 去开/关，这里不当"外点"
                if self.statusItemRect.contains(NSEvent.mouseLocation) { return }
                self.hidePanel()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// 返回 true 表示这枚按键已经吃掉，false 表示原样放行
    private func handlePanelKey(code: UInt16) -> Bool {
        guard let panel, panel.isVisible, panel.isKeyWindow else { return false }
        // 正在搜索框里打字：方向键要移光标、Return 什么也别做
        if panel.firstResponder is NSTextView { return false }
        switch code {
        case 126: moveKeyRow(-1); return true      // ↑
        case 125: moveKeyRow(1); return true       // ↓
        case 36, 76: activateKeyRow(); return true // Return / 小键盘 Enter
        case 53:
            // Esc：搜索框已经收起、但列表还被筛选词筛着 —— 先把筛选清掉（列出全部），
            // 再按一次才收面板。不然收起之后就没有「一键看全部」的地方了。
            if !ui.searchActive, !ui.query.isEmpty {
                ui.applySearch("")
                return true
            }
            hidePanel()
            return true
        default: return false
        }
    }

    /// 行的顺序直接从布局里读：rowFrames 是按纵坐标记的，折叠、分组、换页签都不用另外算
    private func moveKeyRow(_ delta: Int) {
        let frames = ui.rowFramesByTab[ui.tab] ?? [:]
        let ids = frames.sorted { $0.value.minY < $1.value.minY }.map(\.key)
        guard !ids.isEmpty else { return }
        let current = ui.keyRow.flatMap { ids.firstIndex(of: $0) }
        let start = current ?? (delta > 0 ? -1 : ids.count)
        let next = min(max(start + delta, 0), ids.count - 1)
        ui.keyRow = ids[next]
    }

    /// Return：有新版本就去下载页；其它行在 Finder 中显示
    private func activateKeyRow() {
        guard let id = ui.keyRow, let row = service.rows.first(where: { $0.id == id }) else { return }
        if row.isUpdate {
            service.openUpdate(for: row)
        } else {
            service.reveal(row.app)
        }
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let n = service.updateCount
        if !scanAnimating { button.image = makeStatusIcon() }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.title = (n > 0 && service.settings.countVisible) ? " \(n)" : ""
        // 菜单栏那颗图标不挂 tooltip：小夭说系统这个黄色气泡「有点烦人」，
        // 有没有新版本看角标数字就够了（2026-11-21）。
    }

    // MARK: - 扫描时三个点沿环转

    /// 模板图是「黑剪影 + alpha」，塞进 CALayer 不会跟菜单栏明暗走，
    /// 所以按当前外观染一份再交给图层。
    private func tintedCGImage(_ image: NSImage, color: NSColor, scale: CGFloat) -> CGImage? {
        let pxW = Int(image.size.width * scale), pxH = Int(image.size.height * scale)
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // bitmapImageRep 的 context 用户空间是像素，不缩放图标只画到一角、只有 1/4 大
        ctx.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 全透明但真有位图的同尺寸图，用来占住菜单栏里图标那一格
    private func blankIcon(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            img.addRepresentation(rep)
        }
        return img
    }

    /// 扫描时的加载动画：拆成两层——箭头不动，「开口环 + 三个点」整层绕中心转。
    /// 因为缺口和点是一体的，点始终待在缺口里，转到哪都看得见；箭头保持朝下。
    private func startScanAnimation() {
        guard !scanAnimating, let button = statusItem.button else { return }
        scanAnimating = true

        let size = makeStatusIcon().size
        button.image = blankIcon(size: size)
        button.wantsLayer = true

        let scale = button.window?.backingScaleFactor ?? 2
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = dark ? .white : .black
        var rect = NSRect(origin: .zero, size: size)
        if let cell = button.cell as? NSButtonCell {
            rect = cell.imageRect(forBounds: button.bounds)
        }

        func imageLayer(_ part: StatusIconPart) -> CALayer {
            let l = CALayer()
            l.frame = rect
            l.contentsGravity = .resizeAspect
            l.contentsScale = scale
            l.contents = tintedCGImage(makeStatusIcon(part), color: color, scale: scale)
            button.layer?.addSublayer(l)
            return l
        }

        // 箭头：静止层，压在环下面
        arrowLayer = imageLayer(.arrow)
        // 环 + 三点：整层旋转（初始角度与静态图一致，切换不跳变）
        let ring = imageLayer(.ringDots)
        ringLayer = ring

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * CGFloat.pi
        spin.duration = Self.spinPeriod
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        // 每圈「快起慢收」：一上来就冲出去，接近转满一圈、三点快回到原位时明显减速，
        // 下一圈再从 0 重新冲。timingFunction 会在每次循环迭代都重新应用，
        // 所以这个节奏会一圈一圈重复，而不是匀速转。
        // 控制点 (0.12, 0.72, 0.28, 1)：起步切线很陡（快），末段趋平（慢）。
        spin.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.72, 0.28, 1.0)
        ring.add(spin, forKey: "spin")
    }

    private func stopScanAnimation() {
        guard scanAnimating else { return }
        scanAnimating = false
        for layer in [ringLayer, arrowLayer].compactMap({ $0 }) {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        ringLayer = nil
        arrowLayer = nil
        statusItem.button?.image = makeStatusIcon()
    }

    /// 菜单栏图标：模板图（开口环 + 三个点 + 箭头）。走 template 渲染，
    /// 系统按菜单栏明暗自动反色。扫描动画把箭头和「环+点」拆成两层分别取。
    private func makeStatusIcon(_ part: StatusIconPart = .full) -> NSImage {
        // 优先用 asset catalog 里的矢量模板图，任意缩放都清晰，设计师能直接改。
        // 三张 SVG 几何完全一致，叠起来就是完整图标：
        // SentryMenuBar（完整）/ SentryArrow（箭头）/ SentryRingDots（环+三点）。
        //
        // 尺寸：SVG 的外框是 22，环只占 19.6/22。按 22pt 画出来环外沿约 19.6pt，
        // 比 23pt 时（外沿 20.5pt）小一点点，仍不超过菜单栏高度。
        let assetSide: CGFloat = 22
        let name: String
        switch part {
        case .full:     name = "SentryMenuBar"
        case .arrow:    name = "SentryArrow"
        case .ringDots: name = "SentryRingDots"
        }
        if let asset = NSImage(named: name)?.copy() as? NSImage {
            asset.size = NSSize(width: assetSide, height: assetSide)
            asset.isTemplate = true
            return asset
        }

        // 兜底：asset 没编进去时（比如 actool 失败），继续用代码现画的 18pt 那版
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let cx = side / 2
            let cy = side / 2

            let ringInset: CGFloat = 1.1
            // 外框是正圆（跟 asset 里的 SVG 一致），扫描时三个点沿它同心转
            let frame = NSBezierPath(ovalIn: NSRect(x: ringInset, y: ringInset,
                                                   width: side - ringInset * 2,
                                                   height: side - ringInset * 2))
            frame.lineWidth = 1.6
            frame.stroke()

            let shaftW: CGFloat = 2.8
            let shaft = NSRect(x: cx - shaftW / 2, y: cy - 1.6, width: shaftW, height: 6.4)
            NSBezierPath(roundedRect: shaft, xRadius: shaftW / 2, yRadius: shaftW / 2).fill()

            let head = NSBezierPath()
            head.move(to: NSPoint(x: cx - 3.9, y: cy - 1.2))
            head.line(to: NSPoint(x: cx + 3.9, y: cy - 1.2))
            head.line(to: NSPoint(x: cx, y: cy - 5.0))
            head.close()
            head.lineJoinStyle = .round
            head.lineWidth = 1.5
            head.fill()
            head.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: Any?) {
        // 右键菜单取消：设置 / 关于 / 退出都搬到了面板底栏，菜单栏图标只剩「开/关面板」。
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
            if service.lastCheck == nil { service.checkAll() }
        }
        updateBadge()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 面板开着时切到别的 App（点别人的窗口、⌘Tab、点菜单栏里的系统图标）要自动收起。
    /// 自建面板没有 NSPopover 的 .transient，就靠全局点击监听 + 应用失活来收。
    /// 点菜单栏图标时应用会先失活，这一下不能把面板收掉，否则紧接着按钮 action
    /// 看到面板已隐藏又把它弹回来，表现就是「点图标只开不关」。
    func applicationDidResignActive(_ notification: Notification) {
        if statusItemRect.contains(NSEvent.mouseLocation) { return }
        hidePanel()
    }

    /// 系统会调用它来确认「关掉窗口后能不能安全恢复状态」。我们只有菜单栏面板和两个窗口，
    /// 全部由 AppKit 恢复，直接返回 true；否则日志里一直有一条告警。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
