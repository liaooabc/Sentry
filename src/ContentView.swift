import AppKit
import SwiftUI

private let warnAmber = Color.orange

extension Notification.Name {
    /// ⌘F：菜单栏点「搜索」后，让搜索框成为第一响应者
    static let updateRadarFocusSearch = Notification.Name("SentryFocusSearch")
    /// 从外面改写搜索框内容（点清除按钮、点最近搜索里的一条）。
    /// 必须走通知：NSTextField 正在编辑时，SwiftUI 的 binding 回写到不了编辑器里，
    /// 不清掉编辑器里的字，界面就会和 ui.query 对不上。
    static let updateRadarSetSearch = Notification.Name("SentrySetSearch")

    /// 点更新通知后传过来的 App id：列表翻到「可更新」并定位到那一行。
    static let urRevealRow = Notification.Name("URRevealRow")
}

/// 顶栏/分段控件/设置页这些「界面壳」的状态。
/// 单独拎成一只对象，是因为列表页用 @ObservedObject 盯着整个 UIState：
/// 任何 @Published 变化都会让两页上百行全部重新求值（实测一次 ~100ms）。
/// 切页签、聚焦搜索框都属于只看壳的事，
/// 放到这边就不会惊动列表了。UIState 里留了同名转发属性，调用方照旧写 ui.tab。
final class ChromeState: ObservableObject {
    @Published var tab: Int = 0
    /// 分段控件里鼠标正停在那一格（nil = 鼠标不在轨道上）
    @Published var hoverTab: Int?
    /// 两格各自在轨道里的位置，用来让选中胶囊滑过去
    @Published var tabFrames: [Int: CGRect] = [:]
    /// 顶栏是不是搜索态：决定右侧显示输入框（而不是「排序 / 搜索」两颗按钮），
    /// 也决定要不要把「最近搜索」列出来。
    @Published var searchActive = false
    /// 面板当前显示的是设置页（点齿轮翻过去，点「返回」翻回来）
    @Published var showSettings = false
    /// 面板当前显示的是「关于」页（点「•••」翻过去，不弹独立窗口）
    @Published var showAbout = false
    /// 关于页是从设置页翻过来的：返回时回到设置页，而不是列表
    @Published var aboutFromSettings = false
}

/// 界面自身的小状态。用 ObservableObject 而不是 @State，因为这台机器只有
/// Command Line Tools，SwiftUI 的宏插件（@State 依赖它）不可用。
final class UIState: ObservableObject {
    /// 界面壳的状态（见 ChromeState 的注释）
    let chrome = ChromeState()
    /// 底栏「扫描」按钮的鼠标悬停状态（自绘玻璃按钮，明暗要自己给）
    let scanHover = HoverBox()
    /// 顶栏「排序 / 搜索」两颗按钮的悬停状态：玻璃垫在 Menu / Button 底下，
    /// 指针事件被上面那层吃掉，interactive 的悬停高亮不会亮，只能自己叠一层
    let sortHover = HoverBox()
    let searchHover = HoverBox()
    /// 「当前哪个页签」。真正的发布源在 chrome 里，列表页不受影响
    var tab: Int {
        get { chrome.tab }
        set { chrome.tab = newValue }
    }
    var hoverTab: Int? {
        get { chrome.hoverTab }
        set { chrome.hoverTab = newValue }
    }
    var tabFrames: [Int: CGRect] {
        get { chrome.tabFrames }
        set { chrome.tabFrames = newValue }
    }
    var searchActive: Bool {
        get { chrome.searchActive }
        set { chrome.searchActive = newValue }
    }
    var showSettings: Bool {
        get { chrome.showSettings }
        set { chrome.showSettings = newValue }
    }
    var showAbout: Bool {
        get { chrome.showAbout }
        set { chrome.showAbout = newValue }
    }
    var aboutFromSettings: Bool {
        get { chrome.aboutFromSettings }
        set { chrome.aboutFromSettings = newValue }
    }

    @Published var query: String = ""
    /// 全部页里每一组是不是收起来了（key -> 收起了没）
    @Published var collapsedGroups: [String: Bool] = [:]
    /// 哪几行展开了更新说明（左键点一下展开，再点收起）
    @Published var expanded: Set<String> = []
    /// 每一行一个独立的小对象：鼠标划过时只重绘那一行，不动整个列表
    let hovers = HoverStore()

    /// 刚点开的那一行：列表要把它滚进视野
    private(set) var lastToggled: String?
    /// 键盘（↑↓）选中的行；Return 打开它的下载页 / 在 Finder 中显示。
    /// 同时作为 List 的 selection 绑定，选中底色由系统画。
    @Published var keyRow: String?
    /// 每一行在列表可视区里的位置（不发布，只给键盘 ↑↓ 排序用）
    var rowFramesByTab: [Int: [String: CGRect]] = [:]

    /// 最近搜索过的关键词，最新的在前，最多 5 条
    @Published var recentSearches: [String] =
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []

    private static let recentKey = "recentSearches"
    private static let recentLimit = 5

    /// 回车时记一条。已经搜过的词再搜一次会挪到最前面，不重复占位。
    func commitSearch(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        list.insert(word, at: 0)
        recentSearches = Array(list.prefix(Self.recentLimit))
        UserDefaults.standard.set(recentSearches, forKey: Self.recentKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    /// 用一条历史记录（或空串）改写搜索框，并让输入框继续拿着焦点
    func applySearch(_ word: String) {
        query = word
        NotificationCenter.default.post(name: .updateRadarSetSearch, object: word)
    }

    func toggleExpanded(_ id: String) {
        // 注意：这里必须整体赋值。对 @Published 的 Set 调 insert/remove 是原地改，
        // 不会经过 setter，也不会发通知，界面（和下面的 onChange）都不会动。
        let wasOpen = expanded.contains(id)
        expanded = wasOpen ? expanded.subtracting([id]) : expanded.union([id])
        lastToggled = id
    }
}

final class HoverBox: ObservableObject {
    @Published var on = false
}

/// 每行一个悬停开关：只重绘被悬停的那一行（文字转白、展开说明换色）。
/// 「高亮条停在哪一行」不放在这里：那是下面 AppKit 覆盖层的事（见 HoverBarView）。
final class HoverStore {
    private var boxes: [String: HoverBox] = [:]

    func box(for id: String) -> HoverBox {
        if let b = boxes[id] { return b }
        let b = HoverBox()
        boxes[id] = b
        return b
    }
}

// MARK: - 悬停高亮条

/// 行的锚点：一个空 NSView，只回答一个问题——这一行此刻在窗口里的哪儿。
/// 之前高亮条的位置是 SwiftUI 的 frame(in: .named("urList")) 报上来的，
/// List 背后的 NSTableView 滚动时，那份坐标既会滞后、也带一段内边距偏差，
/// 实测整条比行高出 8pt 多。窗口坐标没有这两个毛病：行被 AppKit 挪到哪，锚点就跟到哪。
final class RowAnchorView: NSView {
    var anchorKey: String = ""
    /// 这一行的悬停开关：高亮条找到这一行时顺便把文字转白
    var box: HoverBox?

    /// 别挡住行里的点击
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            RowAnchorStore.shared.remove(self)
        } else {
            RowAnchorStore.shared.add(self)
        }
    }
}

/// 还挂在屏幕上的行锚点（弱引用：行被 List 回收后自然消失）
final class RowAnchorStore {
    static let shared = RowAnchorStore()
    private let views = NSHashTable<RowAnchorView>.weakObjects()

    func add(_ view: RowAnchorView) { views.add(view) }
    func remove(_ view: RowAnchorView) { views.remove(view) }

    /// 鼠标（窗口坐标）压在哪一行上。key 的前缀是页号，把隐藏着的那一页的行挡掉。
    /// 用 objectEnumerator 而不是 allObjects：滚动时这函数每帧都跑，少分配一次数组
    func hit(at point: CGPoint, page: Int) -> RowAnchorView? {
        let prefix = "\(page)#"
        let e = views.objectEnumerator()
        while let view = e.nextObject() as? RowAnchorView {
            guard view.window != nil, view.anchorKey.hasPrefix(prefix) else { continue }
            if view.convert(view.bounds, to: nil).contains(point) { return view }
        }
        return nil
    }
}

/// 把锚点挂进行里
private struct RowAnchor: NSViewRepresentable {
    let anchorKey: String
    let box: HoverBox

    func makeNSView(context: Context) -> RowAnchorView {
        let view = RowAnchorView()
        view.anchorKey = anchorKey
        view.box = box
        return view
    }

    func updateNSView(_ view: RowAnchorView, context: Context) {
        // List 会复用行宿主：同一个锚点可能已经换成另一行了。
        // 旧行那份「悬停中」必须当场熄掉，否则它会一直白着，
        // 而蓝块早跟着指针滑到别处了 —— 看到的就是「文字白、没有蓝底」。
        if view.anchorKey != anchorKey, view.box?.on == true {
            view.box?.on = false
        }
        view.anchorKey = anchorKey
        view.box = box
    }
}

/// 高亮条本体：一块系统选中色，压在 List 底下（行的背景是透明的）。
/// 它自己盯着鼠标：每 1/60 秒在行锚点里找「哪个矩形包住了指针」。
/// 不用 SwiftUI 的 .onHover，是因为滚动时行从指针底下走过去不会再发悬停事件。
///
/// 滚动时行视图的坐标是滞后的，按它去追行只会得到「一帧一个行」的乱跳；
/// 所以滚动期间（含惯性）蓝块原地不动，滚动停下后再滑到指针下那一行。
///
/// 横向（左右滑出按钮）反过来：行在横移，蓝块必须跟着行内容走 ——
/// 不跟的话滑出来的按钮会被压在蓝块底下、行内容跑到框外面。但「跟」也分两种：
/// 手势进行中直接跟（拖拽不能有滞后），其它时候（行自己滑开/弹回）走一根硬弹簧，
/// 把一帧 112pt 的跳变摊成 70ms 的位移，看起来是「滑过去」而不是「跳过去」。
final class HoverBarView: NSView {
    /// 真正那块蓝底。外层视图的 frame 归 SwiftUI 管（铺满整页），
    /// 这一块的 frame 由我们每帧自己摆——否则 SwiftUI 每次布局都会把它拉回整页
    private let block = NSVisualEffectView()
    private let page: Int
    private var timer: Timer?
    private var scrollMonitor: Any?
    /// 正在显示（淡入淡出分别由 alphaValue 负责）
    private var shown = false
    /// 竖直方向的弹簧：位置 + 速度
    private var springY: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var springTargetY: CGFloat = 0
    private var lastFrameTime: TimeInterval = 0
    /// 上一次收到滚轮（含惯性）的时刻：用它判断「现在是不是在滚」
    private var lastScrollTime: TimeInterval = 0
    /// 横滑（左右滑出按钮）的截止时刻。横滑和竖滚都是 scrollWheel 事件，
    /// 但两者要的东西正好相反：竖滚时蓝块必须冻住（行在换，跟着跑会跳），
    /// 横滑时蓝块必须跟着行走（行在横移）。所以按手势方向分开处理。
    private var horizontalUntil: TimeInterval = 0
    /// 上一帧行锚点给的 y：指针没动、它却在变，就说明是内容在滚
    private var lastTargetY: CGFloat = .nan
    /// 上一帧行锚点给的高度。高度是会突变的（点开/收起更新说明时行自己长高），
    /// 而 y 走的是弹簧 —— 两者不同步就会拼出一个「旧位置 + 新高度」的方块。
    private var lastHeight: CGFloat = 0
    /// 上一帧命中的是同一行吗。用来区分「点开说明（同一行在长高）」和
    /// 「滑到别的行（List 复用会产生一帧旧位置 + 新高度的错位锚点）」。
    private var lastAnchorKey: String = ""
    /// 蓝块的高度也走弹簧，跟 y 用同一组参数。
    /// 不这么做的话：普通行（~40pt）滑到展开说明的行（~86pt），高度那一帧就变成 86，
    /// 可 y 还留在上一行 —— 方块往上/下冒出去一截，看着就是「预选框跳了一下」。
    /// y 和高度一起插值，才是整块从一个矩形滑到另一个矩形。
    private var springH: CGFloat = 0
    private var velocityH: CGFloat = 0
    private var springTargetH: CGFloat = 0
    /// 蓝块的横向位置 + 宽度。它俩也跟行内容走，但走的是「硬弹簧」而不是瞬移：
    /// 行被左/右滑开时，锚点会从 14/336 一帧跳到 126/238（滑出按钮的那段被裁掉了），
    /// 直接赋值看着就是「预选框啪地跳一下」；用一根很硬的弹簧滑过去，
    /// 连续横滑时几乎看不出滞后，跳跃也被摊成 70ms 的位移。
    /// 横滑进行中（有连续的横滑事件）则直接赋值 —— 那会儿是手指在拖，滞后就是错位。
    private var springX: CGFloat = .nan
    private var velocityX: CGFloat = 0
    private var springW: CGFloat = .nan
    private var velocityW: CGFloat = 0
    /// 抓不到行的起始时刻：行间隙、组标题、滚动中行视图正在换，都先按原样停一会儿
    private var missingSince: TimeInterval = 0
    /// 上一帧指针在窗口里的位置：用来区分「指针移动」和「内容在滚」
    private var lastPoint: CGPoint?
    /// 上一帧是不是在滚动：用来抓「滚动刚停」的那一瞬间
    private var wasScrolling = false
    /// 在这个时刻之前，对齐一律走快速贴合（滚动刚停的收尾）
    private var quickUntil: TimeInterval = 0
    private weak var hovered: RowAnchorView?
    /// 最后点亮的那一份文字状态。不能只靠 hovered 记：行宿主会被 List 复用，
    /// 同一个锚点换了行之后，旧的那份还亮着，得由这里负责熄掉。
    private weak var litBox: HoverBox?

    init(page: Int) {
        self.page = page
        super.init(frame: .zero)
        block.material = .selection
        block.blendingMode = .withinWindow
        block.state = .active
        block.isEmphasized = true
        block.wantsLayer = true
        block.layer?.cornerRadius = 12
        block.layer?.cornerCurve = .continuous
        block.layer?.masksToBounds = true
        block.autoresizingMask = []
        block.alphaValue = 0
        block.isHidden = true
        addSubview(block)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 别挡住行里的点击
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            startTimer()
        }
    }

    /// 页被拆掉 / 被隐藏时收尾
    func stop() {
        stopTimer()
        shown = false
        missingSince = 0
        block.alphaValue = 0
        block.isHidden = true
        clearHover()
    }

    /// 把点亮的那一行熄掉。
    /// hover.on 只负责文字颜色，蓝底是这块 AppKit 视图自己画的：
    /// 只要有一条路径漏了复位，界面上就会剩下一行「白字、没有蓝底」。
    private func clearHover() {
        if litBox?.on == true { litBox?.on = false }
        litBox = nil
        hovered = nil
    }

    /// 自己这一层到窗口之间有没有被隐藏 / 透明掉。
    /// 两个页签的列表是常驻的（见 PageClipView），隐藏的那一页只是 alphaValue = 0：
    /// 它的行锚点照样躺在窗口坐标上，Tick 会误判成「指针压在这一行」，
    /// 于是把文字点亮，蓝块却画在透明的页里 —— 当前页看着就是「某一行莫名白字」。
    /// 面板 orderOut 之后同理：窗口不可见，继续 Tick 只会留下脏状态。
    private var effectivelyVisible: Bool {
        var v: NSView? = self
        while let cur = v {
            if cur.isHidden || cur.alphaValue < 0.01 { return false }
            v = cur.superview
        }
        return true
    }

    /// 不可见时收干净，但**不停 Timer**：页面重新显示时没有别的东西会把 Timer 叫起来。
    private func suspend() {
        clearHover()
        guard shown || !block.isHidden else { return }
        shown = false
        missingSince = 0
        block.alphaValue = 0
        block.isHidden = true
        velocityY = 0
        velocityH = 0
        velocityX = 0
        velocityW = 0
        lastPoint = nil
        lastTargetY = .nan
        lastHeight = 0
        lastAnchorKey = ""
        wasScrolling = false
    }

    // MARK: 跟随

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        // .common：滚轮滚动、菜单跟踪时也要照常跑
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 滚轮（含惯性）只用来判断「现在在滚」，方向、速度都不需要：
        // 滚动期间蓝块就停在原地，等滚完了再归位
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.noteScroll(event)
            return event
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func noteScroll(_ event: NSEvent) {
        guard let window else { return }
        // 惯性滚动的 event.window 可能不是我们这扇窗，所以只按指针位置判断
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastScrollTime = now
        // 横向为主（系统左右滑出按钮靠的就是这种连续横向滚动）：
        // 记一个截止时刻，这期间不许冻住，否则蓝块会停在滑动前的位置，松手才"啪"地跳过去
        if ScrollGestureAxis.isHorizontal(deltaX: event.scrollingDeltaX,
                                         deltaY: event.scrollingDeltaY) {
            // 0.5s 足够盖住惯性尾巴和松手回弹；每来一个事件都会往后推
            horizontalUntil = now + 0.5
        }
    }

    private func tick() {
        // 窗口不可见（面板被 orderOut）、自己所在的那一层被藏起来（另一个页签）、
        // 或者还没布局出尺寸：一帧都不该干活，而且要把已点亮的行熄掉。
        guard let window, window.isVisible, bounds.width > 1, effectivelyVisible else {
            suspend()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if HoverBarView.fpsDebug, page == 0 { noteFrameGap(now) }
        // dt 卡上限：偶尔卡一帧也不会让弹簧冲出去
        let dt = min(max(now - lastFrameTime, 1.0 / 240.0), 0.05)
        lastFrameTime = now

        // 竖滚中：蓝块原地冻住，这一帧不去找行、不动画、也不碰 SwiftUI。
        // 滚动是主线程最忙的时候（列表还在换行），每帧省一次全锚点遍历和行高亮切换。
        // 横滑例外：那是在滑开行、行本身在横移，冻住就会错位（见 horizontalUntil）
        if shown, now - lastScrollTime < 0.15, now >= horizontalUntil {
            velocityY = 0
            velocityH = 0
            velocityX = 0
            velocityW = 0
            springTargetY = springY
            springTargetH = springH
            return
        }

        let inWindow = window.mouseLocationOutsideOfEventStream
        let point = convert(inWindow, from: nil)
        // 阈值放得很小：鼠标慢慢挪也算「动了」，不然慢速划过时会变成瞬移，一快一慢
        let pointerMoved = lastPoint.map { hypot(point.x - $0.x, point.y - $0.y) > 0.1 } ?? true
        lastPoint = point

        // 指针离开整页：这才是真的离开
        guard bounds.contains(point) else {
            dismiss()
            return
        }

        // 横滑中行会被推开（右边滑出按钮 → 行内容整体右移，锚点从 14 缩到 126），
        // 这时指针脚下可能「暂时没有行了」—— 但用户明明还在这一行上滑。
        // 这期间认住原来那一行，别让蓝块在滑到一半时淡出。
        let swipingNow = now < horizontalUntil || now - lastScrollTime < 0.15
        var target: RowAnchorView? = RowAnchorStore.shared.hit(at: inWindow, page: page)
        if target == nil, swipingNow, let held = hovered, held.window != nil {
            target = held
        }

        guard let hit = target else {
            // 还在页里却没压到行：行间隙、组标题，或者滚动中行视图正在换。
            // 先原地停住别淡出，超过 0.35s 还是抓不到才收起来
            if shown {
                if missingSince == 0 { missingSince = now }
                if now - missingSince < 0.35 { return }
            }
            dismiss()
            return
        }
        missingSince = 0

        let rect = convert(hit.convert(hit.bounds, to: nil), from: nil)
            .insetBy(dx: 0, dy: 1)
            .intersection(bounds)
        // 几何不成立时不能先点亮文字：那正是「白字、没有蓝底」的另一种来源
        //（行被面板边缘裁掉、只剩一条窄缝时就会走到这里）。
        guard !rect.isNull, rect.width > 2, rect.height > 2 else { return }
        setHovered(hit)

        if !shown {
            shown = true
            wasScrolling = false
            springY = rect.minY
            velocityY = 0
            springTargetY = rect.minY
            lastTargetY = rect.minY
            lastHeight = rect.height
            springH = rect.height
            velocityH = 0
            springTargetH = rect.height
            springX = rect.minX
            springW = rect.width
            velocityX = 0
            velocityW = 0
            block.isHidden = false
            block.frame = CGRect(x: springX, y: springY, width: springW, height: springH)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                self.block.animator().alphaValue = 1
            }
            return
        }

        // 行高突变分两种，处理方式必须不同：
        //  1) 点开/收起说明：同一行，y 没动，只是行自己长高/变矮 → y 和高度都原地贴合，
        //     不贴合的话蓝框会拖着弹簧慢慢追，看着就是「点简介时预选框跳一下」。
        //  2) 滑到别的行：y 会变，而且 List 复用行宿主时还会给一帧
        //     「旧位置 + 新高度」的错位锚点 → 绝不 snap y，一律走弹簧，
        //     不然那一帧的错位置会把蓝框钉到上一行（滑动时往上跳）。
        let heightJump = abs(rect.height - lastHeight) > 1
        let sameRow = hit.anchorKey == lastAnchorKey
        let ySteady = lastTargetY.isFinite && abs(rect.minY - lastTargetY) < 6
        lastHeight = rect.height
        lastAnchorKey = hit.anchorKey
        if heightJump, sameRow, ySteady {
            springY = rect.minY
            velocityY = 0
            springTargetY = rect.minY
            lastTargetY = rect.minY
            springH = rect.height
            velocityH = 0
            springTargetH = rect.height
            wasScrolling = false
        }

        let scrolling = (!pointerMoved && lastTargetY.isFinite && abs(rect.minY - lastTargetY) > 0.05)
            || now - lastScrollTime < 0.15
        lastTargetY = rect.minY
        if pointerMoved {
            // 指针自己在动：弹簧滑过去，这是手感最好的那种
            wasScrolling = false
            let omega: CGFloat = 19
            let zeta: CGFloat = 0.82
            springTargetY = rect.minY
            velocityY += (omega * omega * (springTargetY - springY) - 2 * zeta * omega * velocityY) * dt
            springY += velocityY * dt
            if abs(springTargetY - springY) < 0.2, abs(velocityY) < 4 {
                springY = springTargetY
                velocityY = 0
            }
            // 高度跟着 y 用同一根弹簧：滑进/滑出展开行时整块一起长/缩，
            // 不再出现「y 还在上一行、高度已经是新行的」那种往上冒的方块
            springTargetH = rect.height
            velocityH += (omega * omega * (springTargetH - springH) - 2 * zeta * omega * velocityH) * dt
            springH += velocityH * dt
            if abs(springTargetH - springH) < 0.2, abs(velocityH) < 4 {
                springH = springTargetH
                velocityH = 0
            }
        } else if scrolling {
            // 正在滚（含惯性）：原地冻住。跟着行跑必然要在换行时跳一整行，滚得越快跳得越密
            wasScrolling = true
            velocityY = 0
            springTargetY = springY
            velocityH = 0
            springTargetH = springH
        } else {
            if wasScrolling {
                wasScrolling = false
                // 滚停之后行锚点可能还会修正一两像素，这期间也走快速贴合，别留尾巴
                quickUntil = now + 0.4
            }
            springTargetY = rect.minY
            springTargetH = rect.height
            if now < quickUntil {
                approach(dt: dt)
            } else {
                let omega: CGFloat = 24
                let zeta: CGFloat = 1.0
                velocityY += (omega * omega * (springTargetY - springY) - 2 * zeta * omega * velocityY) * dt
                springY += velocityY * dt
                if abs(springTargetY - springY) < 0.2, abs(velocityY) < 4 {
                    springY = springTargetY
                    velocityY = 0
                }
                velocityH += (omega * omega * (springTargetH - springH) - 2 * zeta * omega * velocityH) * dt
                springH += velocityH * dt
                if abs(springTargetH - springH) < 0.2, abs(velocityH) < 4 {
                    springH = springTargetH
                    velocityH = 0
                }
            }
        }
        advanceHorizontal(dt: dt, targetX: rect.minX, targetW: rect.width,
                          direct: now < horizontalUntil)
        block.frame = CGRect(x: springX, y: springY, width: springW, height: springH)

        // 调试：`defaults write com.hushixiong.sentry UR_DEBUG_HOVER -bool YES` 后
        // 每帧把「锚点要的矩形 / 蓝块实际摆的矩形」追加到 /tmp/hoverbar.log。
        // 排查「展开说明时蓝块跳一下、还多出方框」这类几何问题，看日志比看录屏准。
        if UserDefaults.standard.bool(forKey: "UR_DEBUG_HOVER") {
            let line = String(format: "t=%.3f key=%@ rect=(x%.1f w%.1f y%.1f h%.1f) spring=(x%.1f w%.1f) sy=%.1f block=(x%.1f w%.1f y%.1f h%.1f) jump=%d mov=%d hsw=%d\n",
                              now, hit.anchorKey, rect.minX, rect.width, rect.minY, rect.height,
                              springX, springW, springY,
                              block.frame.minX, block.frame.width,
                              block.frame.minY, block.frame.height,
                              heightJump ? 1 : 0, pointerMoved ? 1 : 0,
                              now < horizontalUntil ? 1 : 0)
            HoverBarView.appendDebug(line)
        }
    }

    /// 横向跟随：连续横滑时直接跟（拖拽不能有滞后），其余时候走一根很硬的弹簧。
    ///
    /// 为什么不能一直直接赋值：行被滑开的那一瞬锚点会 `x14 w336 → x126 w238` 一帧跳过去，
    /// 直接赋值看着就是「预选框啪地跳一下」；也不能一直写死 —— 那行内容滑走后
    /// 预选框还停在原地，滑出来的按钮被压在蓝块底下，就是「跟不好」。
    private func advanceHorizontal(dt: TimeInterval, targetX: CGFloat, targetW: CGFloat, direct: Bool) {
        if !springX.isFinite {
            springX = targetX
            springW = targetW
            velocityX = 0
            velocityW = 0
            return
        }
        if direct {
            springX = targetX
            springW = targetW
            velocityX = 0
            velocityW = 0
            return
        }
        let omega: CGFloat = 42
        let zeta: CGFloat = 1.0
        velocityX += (omega * omega * (targetX - springX) - 2 * zeta * omega * velocityX) * dt
        springX += velocityX * dt
        velocityW += (omega * omega * (targetW - springW) - 2 * zeta * omega * velocityW) * dt
        springW += velocityW * dt
        if abs(targetX - springX) < 0.2, abs(velocityX) < 2 {
            springX = targetX
            velocityX = 0
        }
        if abs(targetW - springW) < 0.2, abs(velocityW) < 2 {
            springW = targetW
            velocityW = 0
        }
    }

    /// 调试文本先攒在内存里，退出时一次性落盘。
    /// 每 0.5s 开一次文件写一行本身就会在主线程上抖一下，
    /// 会污染「滚动掉帧」的测量结果。
    static var debugBuffer: [String] = []

    static func flushDebug() {
        guard !debugBuffer.isEmpty else { return }
        let text = debugBuffer.joined()
        debugBuffer.removeAll()
        try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/hoverbar.log"))
    }

    private static func appendDebug(_ line: String) {
        debugBuffer.append(line)
    }

    // MARK: - 掉帧采样（仅 UR_DEBUG_FPS=1 时）

    static let fpsDebug = ProcessInfo.processInfo.environment["UR_DEBUG_FPS"] == "1"
    private var fpsPrev: TimeInterval = 0
    private var fpsWindowStart: TimeInterval = 0
    private var fpsCount = 0
    private var fpsSum = 0.0
    private var fpsMax = 0.0
    private var fpsDrops = 0

    /// 60Hz 的 Timer 本身就会被主线程的活拖慢，所以「相邻两次 tick 的间隔」
    /// 正好就是主线程的卡顿：>20ms 记一次掉帧（60fps 的预算 16.7ms）。
    private func noteFrameGap(_ now: TimeInterval) {
        defer { fpsPrev = now }
        guard fpsPrev > 0 else { fpsWindowStart = now; return }
        let gap = now - fpsPrev
        if fpsWindowStart == 0 { fpsWindowStart = now }
        fpsCount += 1
        fpsSum += gap
        fpsMax = max(fpsMax, gap)
        if gap > 0.020 { fpsDrops += 1 }
        if now - fpsWindowStart >= 0.5 {
            let line = String(format: "frames=%d avg=%.1fms max=%.1fms drops=%d\n",
                              fpsCount, fpsSum / Double(max(fpsCount, 1)) * 1000,
                              fpsMax * 1000, fpsDrops)
            HoverBarView.appendDebug(line)
            fpsWindowStart = now
            fpsCount = 0
            fpsSum = 0
            fpsMax = 0
            fpsDrops = 0
        }
    }

    /// 停滚后立刻贴合：指数收敛，约 4 帧（~70ms）到位。
    /// 肉眼看到的是「已经在那儿了」，而不是「又滑了半行」。
    private func approach(dt: TimeInterval) {
        let k = CGFloat(1 - exp(-dt / 0.012))
        springY += (springTargetY - springY) * k
        velocityY = 0
        if abs(springTargetY - springY) < 0.4 { springY = springTargetY }
        springH += (springTargetH - springH) * k
        velocityH = 0
        if abs(springTargetH - springH) < 0.4 { springH = springTargetH }
    }

    private func setHovered(_ view: RowAnchorView) {
        let box = view.box
        // 不能只比 view 的身份：List 复用行宿主时，同一个锚点的 box 会被换成另一行的。
        // 只比身份就会「认为已经点亮过了」而直接 return，结果新行不亮、旧行一直亮着。
        guard hovered !== view || litBox !== box else { return }
        hovered = view
        if litBox !== box {
            litBox?.on = false
            litBox = box
        }
        if box?.on != true { box?.on = true }
    }

    private func dismiss() {
        clearHover()
        velocityY = 0
        velocityH = 0
        lastTargetY = .nan
        lastHeight = 0
        lastAnchorKey = ""
        velocityX = 0
        velocityW = 0
        missingSince = 0
        wasScrolling = false
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.block.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.block.isHidden = true
        })
    }
}

private struct HoverBarOverlay: NSViewRepresentable {
    let page: Int

    func makeNSView(context: Context) -> HoverBarView {
        HoverBarView(page: page)
    }

    func updateNSView(_ view: HoverBarView, context: Context) {}

    static func dismantleNSView(_ view: HoverBarView, coordinator: ()) {
        view.stop()
    }
}

/// 「全部」页的一组
private struct RowGroup {
    let key: String
    let title: String
    let rows: [AppRow]
}

/// 按当前排序方式取比较函数。三个选项各按各的依据：
/// - 名称：localizedStandardCompare，中文按拼音，跟访达里看到的一致
/// - 最近使用：Spotlight 的 kMDItemLastUsedDate，最近开过的在前
/// - 安装时间：.app 的创建时间，最近装的在前
private func sorter(_ mode: SortMode) -> (AppRow, AppRow) -> Bool {
    switch mode {
    case .name:
        return { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    case .recent:
        return { a, b in
            // 从没启动过、或 Spotlight 没索引到的没有时间，统一排最后；时间相同再按名字
            let x = a.app.lastUsedAt ?? .distantPast
            let y = b.app.lastUsedAt ?? .distantPast
            if x == y { return a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending }
            return x > y
        }
    case .installed:
        return { a, b in
            // 从别处拷来的包没有创建时间，统一排最后；时间相同再按名字，顺序才稳定
            let x = a.app.installedAt ?? .distantPast
            let y = b.app.installedAt ?? .distantPast
            if x == y { return a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending }
            return x > y
        }
    }
}

/// 「可更新」页的行：只列有新版本的，按当前排序方式排
@MainActor
private func computeVisibleRows(_ service: UpdateService, _ ui: UIState) -> [AppRow] {
    service.rows
        .filter { !service.settings.ignored.contains($0.id) && $0.isUpdate }
        // 搜索词也要筛这一页：以前只有「其他」页筛，在「可更新」里打字列表纹丝不动，
        // 看着就像搜索坏了（搜索框是两个页签共用的）
        .filter { ui.query.isEmpty || $0.app.name.localizedCaseInsensitiveContains(ui.query) }
        .sorted(by: sorter(service.settings.sort))
}

/// 顺序照用户要的：可更新 → 已是最新 → 无检测源 → 检测失败（放最后）→ 已忽略
@MainActor
private func computeRowGroups(_ service: UpdateService, _ ui: UIState) -> [RowGroup] {
    let ignoredIds = Set(service.settings.ignored)
    var base = service.rows
    if service.settings.hideUnknownEnabled {
        base = base.filter { $0.hasSource || ignoredIds.contains($0.id) }
    }
    if service.settings.hideFailedEnabled {
        base = base.filter { $0.status != .failed || ignoredIds.contains($0.id) }
    }
    if !ui.query.isEmpty {
        base = base.filter { $0.app.name.localizedCaseInsensitiveContains(ui.query) }
    }
    let order = sorter(service.settings.sort)
    let ignored = base.filter { ignoredIds.contains($0.id) }.sorted(by: order)
    let live = base.filter { !ignoredIds.contains($0.id) }
    var groups = [
        RowGroup(key: "update", title: "可更新", rows: live.filter { $0.status == .updateAvailable }.sorted(by: order)),
        RowGroup(key: "latest", title: "已是最新", rows: live.filter { $0.status == .upToDate }.sorted(by: order)),
        RowGroup(key: "unknown", title: "无检测源", rows: live.filter { $0.status == .unknown }.sorted(by: order)),
        RowGroup(key: "failed", title: "检测失败", rows: live.filter { $0.status == .failed }.sorted(by: order)),
        RowGroup(key: "ignored", title: "已忽略", rows: ignored),
    ]
    // 这一页叫「其他」，平时就不列有更新的 App（它们在上一个页签里）；
    // 但当用户在搜索时得能搜到全部，不然"搜不到"会被当成软件坏了。
    if ui.query.isEmpty { groups.removeAll { $0.key == "update" } }
    return groups.filter { !$0.rows.isEmpty }
}

struct ContentView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var ui: UIState
    /// 设置页要显示本软件的版本和自更新状态
    @ObservedObject var updater: SelfUpdater
    /// 界面壳的状态（顶栏、分段控件、设置页）。列表页不看它，切页签才不惊动列表
    @ObservedObject private var chrome: ChromeState
    /// 底栏「⏻」：退出
    var onQuit: () -> Void = {}

    init(service: UpdateService, ui: UIState, updater: SelfUpdater,
         onQuit: @escaping () -> Void = {}) {
        _service = ObservedObject(wrappedValue: service)
        _ui = ObservedObject(wrappedValue: ui)
        _updater = ObservedObject(wrappedValue: updater)
        _chrome = ObservedObject(wrappedValue: ui.chrome)
        self.onQuit = onQuit
    }

    private var visibleRows: [AppRow] { computeVisibleRows(service, ui) }
    private var rowGroups: [RowGroup] { computeRowGroups(service, ui) }

    var body: some View {
        // 顶部条和底栏不再作为"占位"排在列表上下，而是挂成列表的安全区内嵌：
        // 行能从条底下穿过去，条自己那层 ultraThinMaterial 把穿过的那几行糊掉，
        // 再叠上 macOS 26 的滚动边缘效果，滑到边上的内容就有一段渐隐，这就是透视感。
        // 老系统没有那条系统 API，纯靠材质兜底，效果弱一点但不会破。
        // 设置不再是独立窗口：点齿轮后内容横向翻过去，点「返回」再翻回列表。
        ZStack {
            // 列表不再用 if/else 换进换出：从设置页点「返回」时如果重新搭 listPage，
            // 两个 PageHost 里的 NSHostingView 都要从头排一遍，采样实测 144ms，就是那个卡顿。
            // 让它一直挂在树上，只用透明度做进出场，页面的显示列表始终是热的。
            listPage
                .opacity(ui.showSettings || ui.showAbout ? 0 : 1)
                // 不要位移：之前列表整体左移 24pt 淡出，底栏那颗齿轮会跟着往左跳一下。
                // 只做淡入淡出，按钮原地不动。
                // 透明时也别接活：设置页没有整块底色，点在空白处不该落到下面的列表行上
                .allowsHitTesting(!ui.showSettings && !ui.showAbout)
                // 进/出用不同节奏：点齿轮进设置页时列表（连同底栏那排按钮）要立刻收掉，
                // 否则设置页是透明地滑过来的，旧底栏会在原地多停一拍才被盖住，看着像没收干净。
                .animation(ui.showSettings || ui.showAbout ? .easeIn(duration: 0.08) : .snappy(duration: 0.26),
                           value: ui.showSettings || ui.showAbout)

            if ui.showSettings {
                settingsPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
            if ui.showAbout {
                aboutPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .clipped()
        .animation(.snappy(duration: 0.26), value: ui.showSettings)
        .animation(.snappy(duration: 0.26), value: ui.showAbout)
        // 图标先在后台暖进缓存：列表里是现取的，第一次切到「其他」页要在主线程上
        // 依次光栅化近百个图标，点一下能卡半秒
        .onChange(of: service.rows.count) {
            IconCache.shared.preload(service.rows.map { $0.app.path })
        }
        // 不铺不透明底色：让 NSPopover 自己的液态玻璃材质透过来
    }

    private var listPage: some View {
        list
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    // MARK: - 设置页

    private var settingsPage: some View {
        // 设置页不用「内容从底栏底下穿过去」那套：这里行比较密，穿过去会糊成一团。
        // 直接把滚动区和底栏分成上下两块，内容滚到底就停在底栏上方。
        VStack(spacing: 0) {
            ScrollView {
                PanelSettingsView(service: service)
            }
            .scrollIndicators(.never)
            .modifier(ScrollEdgeBlur())

            settingsFooter
        }
    }

    /// 设置页的底栏：返回 · 版本号 · 关于 · 退出（跟参考图同一套排列）。
    /// 返回用文字胶囊，右边圆钮仍然交给系统玻璃。
    private var settingsFooter: some View {
        HStack(spacing: 8) {
            backCapsule { ui.showSettings = false }

            Text("版本 \(updater.currentVersion)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            footerButton("ellipsis") {
                ui.aboutFromSettings = true
                // 设置页收起来：两页都透明底色，叠在一起会透出下面的设置内容
                ui.showSettings = false
                ui.showAbout = true
            }
            footerButton("power") { onQuit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // 同顶部条：底栏直接坐在系统液态玻璃上，不再另垫材质
    }

    /// 关于页：跟设置页同一套语言——顶部图标 + 名称，下面「信息」「反馈」两张玻璃卡片，
    /// 版权落在卡片和底栏之间。
    private var aboutPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 84, height: 84)

                Text("Sentry")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 2)

                Text("有新版就提醒你，数据只存在本机。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            // 版本 / 检查更新这一行原来在设置页，现在搬到关于页——设置页里就不必再放一份
            aboutSection("信息") {
                AboutControlRow(symbol: "number", title: "当前版本") {
                    HStack(spacing: 8) {
                        Text("\(updater.currentVersion)（\(appBuild)）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let page = releasePageURL {
                            Button("发布说明") { NSWorkspace.shared.open(page) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Button("检查更新") { updater.check() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(updater.isChecking)
                        }
                    }
                }
                AboutValueRow(symbol: "laptopcomputer", title: "系统",
                              value: macOSName, showDivider: hasAvailableUpdate)
                if case let .available(version, downloadURL, _, hasDMG) = updater.phase {
                    AboutControlRow(symbol: "square.and.arrow.down",
                                    title: "安装 \(version)", showDivider: false) {
                        if hasDMG {
                            ConfirmingButton(title: "更新并重启",
                                             dialogTitle: "现在下载并安装 \(version)？",
                                             confirmTitle: "更新并重启",
                                             message: "会下载安装包、替换当前 App，然后自动重新打开。") {
                                updater.install(version: version, downloadURL: downloadURL)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if let url = URL(string: downloadURL) {
                            Button("下载") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            aboutSection("反馈") {
                AboutLinkRow(symbol: "envelope", title: "邮件反馈",
                             value: "2598492427@qq.com") {
                    NSWorkspace.shared.open(feedbackMail)
                }
                AboutLinkRow(symbol: "link", title: "GitHub",
                             value: "在浏览器打开", showDivider: false) {
                    NSWorkspace.shared.open(githubIssues)
                }
            }

            Spacer(minLength: 0)

            Text(appCopyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)

            aboutFooter
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// 和设置页 section 同款：小号标题 + 系统玻璃卡片 + 行内细分隔线
    private func aboutSection<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .modifier(SettingsCard())
        }
        .padding(.bottom, 14)
    }

    private var aboutFooter: some View {
        HStack(spacing: 8) {
            // 从设置页翻过来的，返回就落回设置页；从列表翻过来的，返回就落回列表
            backCapsule {
                ui.showAbout = false
                if ui.aboutFromSettings { ui.showSettings = true }
            }
            Spacer(minLength: 0)
            footerButton("power") { onQuit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func backCapsule(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("返回")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            // 系统玻璃按钮会在内容外补 4pt/边，所以内容给 18pt，画出来正好 26pt
            .frame(height: 18)
            .contentShape(Capsule())
        }
        .modifier(GlassCapsuleButton())
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var appCopyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Sentry · 保留所有权利"
    }

    /// 反馈邮件入口：收件人、标题、版本和系统版本都预填好，用户只补问题描述。
    /// 用 mailto 而不是只有 GitHub Issues，是因为不少用户打不开 GitHub。
    private var feedbackMail: URL {
        let version = "\(updater.currentVersion)（\(appBuild)）"
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = "2598492427@qq.com"
        mail.queryItems = [
            URLQueryItem(name: "subject", value: "Sentry 反馈（版本 \(updater.currentVersion)）"),
            URLQueryItem(name: "body",
                         value: "\n\n\n——\n版本：\(version)\nmacOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        ]
        return mail.url!
    }

    /// 「关于」页里的系统行：只留主次版本号，完整 build 号太长会把一行撑满
    private var macOSName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    private var githubIssues: URL {
        URL(string: "https://github.com/liaooabc/Sentry/issues")!
    }

    /// 有新版本时，关于页的版本行改显示「发布说明」，顺带把安装行一起露出来
    private var releasePageURL: URL? {
        if case let .available(_, _, page, _) = updater.phase { return URL(string: page) }
        return nil
    }

    private var hasAvailableUpdate: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    private var topBar: some View {
        // 扫描中不再显示进度条：试过三种做法（直接绑值、SwiftUI 补间、Core Animation），
        // 弹层里都换不来"匀速"，反而更卡。进度改成由底栏那颗扫描图标转圈表示。
        tabBar
        // 不垫任何自绘材质：上下栏就是 Apple 液态玻璃本身，
        // 滚动边缘的糊化交给系统 ScrollEdgeBlur。
    }

    // MARK: - 分段

    private static let barControlHeight: CGFloat = 26      // 分段轨道、按钮和搜索框的统一高度
    /// 顶栏右侧两颗按钮各占一半：(94 - 5) / 2。94 = 底栏三颗圆钮那一排的宽度（26×3 + 8×2）
    private static let halfControlWidth: CGFloat = (barControlHeight * 3 + 16 - 5) / 2

    private var tabBar: some View {
        HStack(spacing: 8) {
            // 轨道是真的液态玻璃（系统 glassEffect），选中的那一段只是一层淡淡的中性胶囊：
            // 不用系统蓝，才对得上照片 App 那个 日/周/月/年。
            HStack(spacing: 2) {
                segButton("可更新 \(service.updateCount)", index: 0)
                segButton("其他 \(rowGroups.reduce(0) { $0 + $1.rows.count })", index: 1)
            }
            .padding(3)
            .coordinateSpace(name: "tabTrack")
            .background(alignment: .topLeading) { tabPreview }
            .onPreferenceChange(TabFrameKey.self) { ui.tabFrames = $0 }
            .modifier(GlassTrack())

            Spacer(minLength: 0)

            // 一颗排序、一颗搜索，两颗平分这一块。
            // 整块宽度跟右下三颗圆钮那一排同宽（26×3 + 间距 8×2 = 94），高度 26、右边缘齐平 ——
            // 位置和宽度都跟换掉的那条常驻搜索框完全一致。
            //
            // 两种状态叠在一起做交叉淡入：两颗按钮淡出＋轻微内收，输入框淡入，
            // 都锚在右边缘，看上去就是同一块玻璃换了内容，而不是「跳一下」。
            // 收起只有一条判据 —— ui.searchActive：点面板里别处、Esc、⌘F 都只改它。
            // （以前还额外要求 !query.isEmpty，于是打过字之后输入框就再也收不回去，
            //   顶栏一直被它占着，排序图标看不见。）
            ZStack(alignment: .trailing) {
                HStack(spacing: 5) {
                    sortButton
                        .frame(width: Self.halfControlWidth, height: Self.barControlHeight)
                    searchButton
                        .frame(width: Self.halfControlWidth, height: Self.barControlHeight)
                }
                .opacity(ui.searchActive ? 0 : 1)
                .scaleEffect(ui.searchActive ? 0.9 : 1, anchor: .trailing)
                // 收起时（searchActive=false）按钮淡入得慢一点，撑住这 0.16 秒的空档；
                // 展开时先快点让开（0.09 秒），别和输入框叠在一起显脏
                .animation(ui.searchActive ? .easeOut(duration: 0.09) : .easeOut(duration: 0.16),
                           value: ui.searchActive)
                .allowsHitTesting(!ui.searchActive)

                if ui.searchActive {
                    searchFieldBar
                        // 错开一拍再淡入：两边同时半透明的话，三条横线会从「搜索」两个字里透出来，
                        // 中间那几帧又糊又乱。先让按钮退干净，输入框再浮出来。
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))
                        ))
                }
            }
            .frame(width: Self.barControlHeight * 3 + 16, height: Self.barControlHeight)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // 最近搜索：贴在搜索框正下方，只在「正在搜索、还没打字、有历史」时出现。
        // 用 padding 而不是 offset 往下推：offset 是渲染期的位移，不会写进布局，
        // 底下那个上报窗口坐标的探针就会拿到偏移前的位置（判断「点没点在浮层里」会错位）。
        .overlay(alignment: .topTrailing) {
            if ui.searchActive, ui.query.isEmpty, !ui.recentSearches.isEmpty {
                recentSearchesPanel
                    .padding(.trailing, 14)
                    .padding(.top, Self.barControlHeight + 18)
            }
        }
        // 动画只挂在 tabPreview 上（见那里）：之前挂在整条 HStack 上，
        // 切页签时连轨道那圈液态玻璃也跟着逐帧重绘，胶囊滑动就掉帧。
        // 换页签时键盘选中的行作废，免得按 ↓ 从上一个页签的位置开始数。
        // 注意要先判空再写：@Published 不管值变没变都会发通知，
        // 无脑赋值会让两页上百行跟着重新求值（切页签那 100ms 有一半是这里来的）
        .onChange(of: ui.tab) {
            if ui.keyRow != nil { ui.keyRow = nil }
        }
        // 两颗按钮是淡出藏起来的（不是移除），藏起来时收不到 onHover(false)，
        // 悬停色会留在开关上：等搜索框收起、按钮再淡回来时，就凭空亮着一颗。
        .onChange(of: ui.searchActive) {
            ui.sortHover.on = false
            ui.searchHover.on = false
        }
    }

    // MARK: - 顶栏右侧：排序 / 搜索

    /// 两颗按钮里的符号。尺寸和重心对齐分段控件的文字，别让图标看着比字大。
    /// active 用来标「有筛选词还生效」：搜索框收起之后，只剩这颗图标能提示列表被筛过。
    private func barGlyph(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// 顶栏两颗按钮共用的玻璃底。
    /// 排序那颗必须画在 Menu **外面**：Menu 会自己重绘 label，加在 label 上的
    /// glassEffect 会被吃掉 —— 实测只剩一个图标浮在那儿，跟旁边的搜索按钮不成对。
    @ViewBuilder private var barGlass: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(Color.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.06))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }

    /// 排序按钮：点开是系统菜单。用 SwiftUI 的 Menu 而不是自己弹 NSMenu ——
    /// 这里只是三条单选项，系统菜单的勾选态、明暗、键盘操作都是现成的，没必要自绘。
    private var sortButton: some View {
        ZStack {
            barGlass
            Menu {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button {
                        service.setSort(mode)
                    } label: {
                        if service.settings.sort == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                barGlyph("line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(width: Self.halfControlWidth, height: Self.barControlHeight)
        .contentShape(Capsule())
        .modifier(BarHoverTint(box: ui.sortHover))
        .onHover { ui.sortHover.on = $0 }
    }

    private var searchButton: some View {
        Button {
            // 输入框这时还不在视图树里，先把搜索态打开，等它建出来再要焦点
            ui.searchActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                NotificationCenter.default.post(name: .updateRadarFocusSearch, object: nil)
            }
        } label: {
            // 过滤词还在（收起了输入框、列表仍是筛过的）时，放大镜染成强调色
            barGlyph("magnifyingglass", active: !ui.query.isEmpty)
                .frame(width: Self.halfControlWidth, height: Self.barControlHeight)
                .modifier(GlassSearchField())
        }
        .buttonStyle(.plain)
        .modifier(BarHoverTint(box: ui.searchHover))
        .onHover { ui.searchHover.on = $0 }
    }

    /// 搜索态：整块 94 宽换回输入框，跟换成按钮之前完全一样（同位置、同宽度、同玻璃）
    private var searchFieldBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SearchField(ui: ui)
                .frame(maxWidth: .infinity)
            // 清除按钮的位置常驻（没字的时候只是透明）：一出现一消失，
            // 整条胶囊的宽度就会跟着跳一下，段落轨道也会跟着挤。
            Button {
                ui.applySearch("")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(ui.query.isEmpty ? 0 : 1)
            .disabled(ui.query.isEmpty)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(GlassSearchField())
        // 把这一整条胶囊的窗口坐标报出去：点在它上面（放大镜、文字、清除钮）不算「点别处」
        .background(WindowRectReporter { SearchHitAreas.shared.bar = $0 })
    }

    /// 搜索框下面的「最近搜索」浮层。宽度比搜索框宽一些，右边缘与搜索框对齐。
    private var recentSearchesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("最近搜索")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("清除") { ui.clearRecentSearches() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 5)

            ForEach(ui.recentSearches, id: \.self) { word in
                Button {
                    ui.applySearch(word)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(word)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressablePlainButton())
            }
        }
        .frame(width: 210)
        .padding(.bottom, 7)
        .modifier(GlassCard())
        .background(WindowRectReporter { SearchHitAreas.shared.recent = $0 })
        .zIndex(2)
    }

    private func segButton(_ label: String, index: Int) -> some View {
        let selected = ui.tab == index
        return Button {
            // 切页签一定不能包在 withAnimation 里：整个列表会跟着换内容，
            // 一动画就成了「旧行淡出、新行滑动入场」，看起来就是列表在抖。
            // 动画只留给 tabBar 自己（见 tabBar 的 .animation）。
            // 两份列表一直挂着，这里只切可见性，不触发任何插入/删除，点下去立刻响应。
            ui.tab = index
        } label: {
            // 透明的那份半粗文本只是占位：选中要变粗，字一变粗字宽就变，
            // 玻璃轨道跟着一两个点地伸缩，切页签时看着就「晃」。锁住宽度最省事。
            ZStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .opacity(0)
                Text(label)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.barControlHeight - 6)   // 轨道上下各留 3pt
            // 文字深浅跟着胶囊一起过渡（0.18s 和胶囊同拍），整条轨道不再做隐式动画
            .animation(.easeInOut(duration: 0.18), value: selected)
            .background {
                // 只量位置，不画背景：胶囊统一由 tabPreview 画，才能在两格之间滑动
                GeometryReader { proxy in
                    Color.clear.preference(key: TabFrameKey.self,
                                           value: [index: proxy.frame(in: .named("tabTrack"))])
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { ui.hoverTab = index }
            else if ui.hoverTab == index { ui.hoverTab = nil }
        }
    }

    /// 选中/悬停胶囊：选中的那格永远有一层 13% 的中性填充，鼠标停到**另一格**时
    /// 那一格先浮出一层更淡的 5% 预览，移开就消失。点下去才真正切过去。
    /// 只留一层柔和填充、不描边——外面已经有轨道那圈边框了，里面再描一圈就是「框中框」。
    private var tabPreview: some View {
        ZStack(alignment: .topLeading) {
            if let f = ui.tabFrames[ui.tab] {
                PillRect(rect: f)
                    .fill(Color.primary.opacity(0.13))
            }
            if let h = ui.hoverTab, h != ui.tab, let f = ui.tabFrames[h] {
                PillRect(rect: f)
                    .fill(Color.primary.opacity(0.05))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: ui.tab)
        .animation(.easeInOut(duration: 0.14), value: ui.hoverTab)
        .allowsHitTesting(false)
    }

    // MARK: - 列表

    private var list: some View {
        // 两个页签各挂一份 List，且一直活着：换页签只切可见性，
        // 不会再让 NSTableView 插入/删除几十行（切到「其他」那半拍的迟钝就是这个），
        // 两份还各自记住自己的滚动位置。
        GeometryReader { _ in
            ZStack(alignment: .top) {
                // 每一页各自住在一个 NSHostingView 里（见 PageHost）：切页签只把宿主左右挪一下，
                // 页面内容既不会因为 ui.tab 变化而重新求值，也不会被裁掉不生成显示列表。
                // 之前两份 List 直接堆在 SwiftUI 里，切一次页签整页近百行全部重算，实测 100ms。
                PageHost(index: 0, ui: ui, service: service, visible: ui.tab == 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PageHost(index: 1, ui: ui, service: service, visible: ui.tab == 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if ui.tab == 0 ? visibleRows.isEmpty : rowGroups.isEmpty {
                    emptyState
                }
            }
        }
        .frame(maxHeight: .infinity)
        // 点更新通知：翻到「可更新」页，把那一行滚到中间并套上焦点框
        .onReceive(NotificationCenter.default.publisher(for: .urRevealRow)) { note in
            guard let id = note.object as? String else { return }
            ui.tab = 0
            // 等页签切换渲染完再滚
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ui.keyRow = id
            }
        }
    }



    /// 空状态按 App Store「更新」页那张空图来：一句大字标题 + 一句灰色说明，不放图标。
    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(ui.tab == 0 ? "无更新" : "没有匹配的 App")
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text(ui.tab == 0 ? "所有 App 均为最新版本。" : "换个关键词试试")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 底栏

    private var footer: some View {
        // 右键菜单已经取消，原来的「设置 / 检测更新 / 退出」全搬到底栏：
        // 左下「重新扫描」（带进度），右下三颗玻璃圆：关于、设置、退出。
        // 胶囊宽度取「可更新 / 其他」整条轨道（两格 + 轨道左右各 3pt padding），
        // 和顶栏共用同一个 14pt 左右边距，所以左边缘天然对齐。
        let trackWidth: CGFloat = {
            guard let a = ui.tabFrames[0], let b = ui.tabFrames[1] else { return 141 }
            return b.maxX - a.minX + 6
        }()
        return HStack(spacing: 8) {
            ScanCapsule(checking: service.checking,
                        width: trackWidth,
                        hover: ui.scanHover) {
                guard !service.checking else { return }
                service.rescan(thenCheck: true, force: true)
            }

            Spacer()

            // 「关于 → 设置 → 退出」顺序，跟参考图同一套排列
            footerButton("ellipsis") {
                ui.aboutFromSettings = false
                ui.showAbout = true
            }
            footerButton("gearshape") { ui.showSettings = true }
            footerButton("power") { onQuit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 底栏按钮：用系统的玻璃按钮样式，悬停明暗由系统给；
    /// 内容框 18pt + 系统补充的 8pt = 画出来 26pt，和原来的尺寸一致
    private func footerButton(_ systemName: String,
                              spinning: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            footerGlyph(systemName, spinning: spinning)
        }
        .modifier(GlassCircleButton())
    }

    private func footerGlyph(_ systemName: String, spinning: Bool) -> some View {
        Group {
            if spinning {
                NativeSpinner()
                    .allowsHitTesting(false)
            } else {
                Image(systemName: systemName)
                    .font(.footnote.weight(.medium))
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
    }
}

/// 一页列表（「可更新」或「其他」）。它住在自己的 NSHostingView 里（见 PageHost），
/// 所以这里只关心「这一页怎么画」，不用管页签切换。
/// 行数据、搜索、展开这些由 @ObservedObject 的发布自动驱动。
private struct ListPage: View {
    let index: Int
    @ObservedObject var ui: UIState
    @ObservedObject var service: UpdateService

    private var rows: [AppRow] { computeVisibleRows(service, ui) }
    private var groups: [RowGroup] { computeRowGroups(service, ui) }

    // MARK: - 行右键菜单

    /// 右键落在哪一行：菜单跟着鼠标走，而鼠标一定停在被右键的那一行上，
    /// 所以直接用悬停状态反查，不用再做坐标换算
    private func hoveredRow() -> AppRow? {
        let visible = index == 0 ? rows : groups.flatMap(\.rows)
        return visible.first { ui.hovers.box(for: $0.id).on }
    }

    /// 行右键菜单：四项固定（打开 / 在访达中显示 / 忽略·提醒更新 / 卸载），
    /// 前面带 SF Symbol 图标。「可更新」页用「忽略更新」，其余页用「提醒更新」
    /// （点了就把忽略 / 已是最新的标记撤掉，之后有新版照常提醒）。
    private func rowMenu(_ row: AppRow, _ handler: MenuHandler) -> NSMenu {
        handler.reset()
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            let item = handler.item(title, run)
            item.attributedTitle = menuTitle(title, symbol)
            menu.addItem(item)
        }
        add("打开", "macwindow") { service.launch(row.app) }
        add("在访达中显示", "folder") { service.reveal(row.app) }

        if index == 0 {
            add("忽略更新", "eye.slash") { service.ignore(row.app) }
        } else {
            add("提醒更新", "bell") {
                service.unignore(row.id)
                service.undismiss(row.id)
            }
        }

        if Uninstaller.canUninstall(row.app) {
            add("卸载", "trash") {
                // 菜单收起后再弹确认框，避免在菜单跟踪循环里再开一个模态窗口
                DispatchQueue.main.async {
                    Uninstaller.present(for: row.app) { service.rescan() }
                }
            }
        }
        return menu
    }

    /// 系统菜单不画 NSMenuItem.image，只能把符号图塞进富文本附件里
    private func menuTitle(_ text: String, _ symbol: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 15, height: 13)
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: "  " + text))
        } else {
            out.append(NSAttributedString(string: text))
        }
        return out
    }

    var body: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                // 共用高亮条压在 List 底下（行的背景是透明的），
                // 所以划过一行时看到的是同一块蓝底滑过去，而不是上一行灭、下一行亮
                ZStack(alignment: .topLeading) {
                HoverBarOverlay(page: index)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                List {
                Color.clear.frame(height: 0).id("top")
                    .listChrome()

                if index == 0 {
                    rowsSection(rows, tabIndex: 0)
                } else {
                    ForEach(Array(groups.enumerated()), id: \.element.key) { groupIndex, group in
                        if groupIndex > 0 {
                            Color.clear.frame(height: 8).listChrome()
                        }
                        // 「已是最新」不画分组标题：每行右侧已经写了「已是最新版本」，
                        // 再顶一行「已是最新 93」就是同一句话说两遍。其余分组标题照旧。
                        if group.key != "latest" {
                            groupHeader(group).listChrome()
                        }
                        // 没有标题就点不到折叠，这一组始终展开
                        if group.key == "latest" || !isCollapsed(group.key) {
                            rowsSection(group.rows,
                                        ignored: group.key == "ignored",
                                        tabIndex: 1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            // 行的右键菜单：自己用 AppKit 弹 NSMenu（见 RowMenuMonitor），
            // 这样系统不会给被右键的行再画一层直角高亮
            .background(RowMenuMonitor(active: { index == ui.tab },
                                       hoveredRow: { hoveredRow() },
                                       buildMenu: { rowMenu($0, $1) }))
            .defaultScrollAnchor(.top)
            .onChange(of: rows.count) {
                // 正在读某一行展开的说明时，别因为后台查完了就把列表甩回顶部
                if index == 0, ui.expanded.isEmpty { scrollTop(proxy) }
            }
            // 行的位置只有「展开说明时要滚一下」才用得上，由展开的那一行自己上报（见 RowView），
            // 收起的行不上报——之前每行都挂 GeometryReader + PreferenceKey，
            // 滚动时每帧都要把上百行的 CGRect 重新合并一遍，这就是上下滚卡顿的来源。
            // 键盘选中的行滚进视野中间；只由当前显示的这份列表来做
            .onChange(of: ui.keyRow) {
                guard index == ui.tab, let id = ui.keyRow else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // 点开一行时**不滚动列表**。
            // 之前这里会在「说明长到面板外」时 scrollTo(.bottom)：点一下靠下的行，
            // 整列就往上顶一截（实测 PDF Squeezer 那行从 y46 顶到 y1、首行从 Mole
            // 变成 Logic Pro），看着就是「内容跳了一下」。现在展开只让这一行自己长高，
            // 列表位置完全不动；看不到底部的说明，用户自己滚一下即可。
            // （keyRow 也不再在点击时设置，见 rowsSection 的 onToggle——两个会自动
            //  滚动的入口都关掉，点简介才真正做到「原地展开」。）
            // 系统的滚动边缘效果：滑到顶/底时，被条遮住的那一段由系统做渐隐，
            // 不是我们自己画的渐变，所以深浅色、壁纸、透明度都跟系统一致。
            .modifier(ScrollEdgeBlur())
                }
            }
            .coordinateSpace(name: "urList")
        }
    }

    /// 归顶要**不带**动画：带 0.18s 动画的归顶会让整列行从旧位置滑到顶部，
    /// 用户看到的就是一次抖动。这里把动画显式关掉。
    private func scrollTop(_ proxy: ScrollViewProxy) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { proxy.scrollTo("top", anchor: .top) }
    }

    @ViewBuilder
    private func rowsSection(_ rows: [AppRow],
                             ignored: Bool = false,
                             tabIndex: Int) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            let anchorKey = "\(tabIndex)#\(row.id)"
            RowView(row: row,
                    service: service,
                    hover: ui.hovers.box(for: row.id),
                    anchorKey: anchorKey,
                    ignored: ignored,
                    expanded: ui.expanded.contains(row.id),
                    // 分隔线自己画：系统的会铺满整行，从图标左边就起，跟名字对不齐
                    showsDivider: index < rows.count - 1,
                    onToggle: {
                        // 点这一行只展开/收起更新说明，**不要动 keyRow**：
                        // keyRow 一变，下面的 .onChange 就会 scrollTo(.center)，
                        // 把整列往上顶一截 —— 用户看着就是「点简介时内容跳了一下」。
                        // keyRow 现在只留给键盘 ↑↓ 和通知深链（见 urRevealRow）。
                        // 也不包 withAnimation：点开/收起是即时的，跟切页签、
                        // 换行、展开全部一致；List 行高本来就一帧到位，包一层
                        // 反而会让文字颜色抢先跳变、和行高不同步。
                        ui.toggleExpanded(row.id)
                    },
                    // 键盘 ↑↓ 要按纵坐标排序，所有行都报位置（原来的做法是只报展开行，
                    // 为了省滚动时的测量开销 —— 但键盘导航依赖完整列表，只能都报）
                    onFrame: { ui.rowFramesByTab[tabIndex, default: [:]][row.id] = $0 })
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // 选中色块的左边要压在「可更新」框的左边缘、右边压在搜索框的右边缘，
            // 也就是顶部条那 14pt 内边距。List 自己还会在左右各加 8pt / 9pt，
            // 这里补差：6 + 8 = 14，5 + 9 = 14。系统滑动时的裁剪边界也落在色块边上。
            .padding(.leading, 6)
            .padding(.trailing, 5)
            .id(row.id)
            // 滑动操作用系统的 swipeActions：跟手位移、越界回弹、松手动画都是 SwiftUI 自己做的。
            // 按钮里只放文字：用 Label 的话系统会把图标塞进胶囊、标题甩到胶囊外面，
            // 行又比系统默认行高得多，那个大胶囊 + 底下孤零零一行字就是最丑的地方。
            // 高度不再写死：行高 = 图标 40 + 上下内边距 4×2 = 48，
            // 滑出来的胶囊由系统按行高自己撑，改行内边距时不用同步这里
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if row.isUpdate {
                    Button { service.dismiss(row) } label: {
                        swipeLabel("已是最新")
                    }
                    .tint(.green)
                } else if service.isDismissed(row.id) {
                    Button { service.undismiss(row.id) } label: {
                        swipeLabel("恢复提醒")
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if ignored {
                    Button { service.unignore(row.id) } label: {
                        swipeLabel("恢复提醒")
                    }
                    .tint(.blue)
                } else {
                    Button { service.ignore(row.app) } label: {
                        swipeLabel("忽略")
                    }
                    .tint(.gray)
                }
            }
        }
    }

    /// 滑动操作的按钮标签：尺寸交给系统决定，不自己撑高度
    private func swipeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }

    /// 搜索的时候强制展开，不然搜到的东西会藏在收起来的组里
    private func isCollapsed(_ key: String) -> Bool {
        ui.query.isEmpty && (ui.collapsedGroups[key] ?? false)
    }

    private func groupHeader(_ group: RowGroup) -> some View {
        let collapsed = isCollapsed(group.key)
        // 点击手势而不是 Button：组标题滚到跟前才建，Button 的控件/焦点链
        // 同样是滚动时的尖峰来源（跟行内 Button 一个道理）。
        return HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(group.rows.count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            ui.collapsedGroups[group.key] = !(ui.collapsedGroups[group.key] ?? false)
        }
        .accessibilityElement()
        .accessibilityLabel("\(group.title)，\(group.rows.count) 个")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            ui.collapsedGroups[group.key] = !(ui.collapsedGroups[group.key] ?? false)
        }
    }
}

/// 页签宿主：把一页列表放进独立的 NSHostingView，SwiftUI 这边只负责「这一页露出来还是藏起来」。
/// 藏的时候用 AppKit 的 alphaValue = 0，宿主始终待在原位、尺寸不变：
///   · SwiftUI 眼里这一页一直在显示，内容一直是渲染好的 —— 切回来只是把 alpha 从 0 拨回 1，
///     不用重新求值，摸过的滚轮位置也还在；
///   · 用 SwiftUI 的 opacity(0) 藏是不行的：SwiftUI 只把可见的那份生成显示列表，
///     藏起来的那页切回来是白的（踩过）；挪出边界也不行，首次显示要现算，第一次切换照样卡 100ms。
///   · 每次切页签让整页重新求值更不行：近百行全重算，实测 100ms，就是那个"慢半拍"。
private struct PageHost: NSViewRepresentable {
    let index: Int
    let ui: UIState
    let service: UpdateService
    let visible: Bool

    func makeNSView(context: Context) -> PageClipView {
        let page = NSHostingView(rootView: ListPage(index: index, ui: ui, service: service))
        page.autoresizingMask = [.width, .height]
        let clip = PageClipView()
        clip.addSubview(page)
        clip.page = page
        clip.setVisible(visible)
        return clip
    }

    func updateNSView(_ clip: PageClipView, context: Context) {
        clip.setVisible(visible)
    }
}

private final class PageClipView: NSView {
    weak var page: NSView?
    private var visible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setVisible(_ v: Bool) {
        guard v != visible else { return }
        visible = v
        page?.alphaValue = v ? 1 : 0
    }

    override func layout() {
        super.layout()
        page?.frame = bounds
        page?.alphaValue = visible ? 1 : 0
    }

    /// 透明（alpha 0）的页在 AppKit 里仍然参与点击命中：它会盖在当前页上面把点击全吃掉。
    /// 所以隐藏的那一页必须在这里直接放行。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visible else { return nil }
        return super.hitTest(point)
    }
}

/// List 的默认装饰（行内边距、白色底、分隔线）全部去掉，
/// 这样行外观完全由 RowView 自己决定，跟改造前的自绘列表一致。
private struct ListChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

extension View {
    func listChrome() -> some View { modifier(ListChrome()) }
}

// MARK: - 玻璃

/// 列表的滚动边缘效果（macOS 26 的液态玻璃）：内容滑到被顶部条 / 底栏遮住的那一段时，
/// 由系统做一层渐进模糊 + 淡出，不是我们自己画渐变，所以深浅色和透明度都跟系统一致。
/// 老系统没有这个 API，就什么都不加——那时靠条自己的 ultraThinMaterial 兜住。
private struct ScrollEdgeBlur: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // .soft 太透，滚到条底下的内容还看得清；.hard 是系统工具栏那档，糊得更实
            content.scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
        } else {
            content
        }
    }
}

/// 自绘玻璃按钮的悬停明暗：鼠标经过时叠一层中性色（深色下变亮、浅色下变暗）
private struct ScanHoverTint: ViewModifier {
    @ObservedObject var box: HoverBox
    func body(content: Content) -> some View {
        content.background {
            Capsule()
                .fill(Color.primary.opacity(box.on ? 0.09 : 0))
                .animation(.easeOut(duration: 0.12), value: box.on)
        }
    }
}

/// 顶栏「排序 / 搜索」的悬停明暗。跟 ScanHoverTint 同一个观感、同一份透明度，
/// 区别只是叠在玻璃**上面**：这两颗的玻璃垫在 Menu / Button 底下，
/// 指针事件被上面那层吃掉，interactive 的悬停高亮永远不亮。
private struct BarHoverTint: ViewModifier {
    @ObservedObject var box: HoverBox
    func body(content: Content) -> some View {
        content.overlay {
            Capsule()
                .fill(Color.primary.opacity(box.on ? 0.09 : 0))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: box.on)
        }
    }
}

/// 底栏「扫描」胶囊：自绘玻璃（悬停由 interactive 给），宽度能精确控制
private struct ScanGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}

/// 扫描胶囊状态。ObservableObject：本机 SwiftUI 宏插件不可用，@State 编不过。
/// 关键：**和菜单栏图标用同一个信号 service.checking** —— 菜单转，进度走；
/// 菜单停，进度补到 100% 显示完成。不再自己写死时长，所以绝不会不同步。
private final class ScanPhase: ObservableObject {
    @Published var started: Date?
    @Published var finishedAt: Date?
    /// 菜单停下那一刻的进度，完成动画从这里补到 100%
    @Published var finishFrom: CGFloat = 0
    @Published var pressed = false

    static let doneHold: TimeInterval = 1.0    // 100% 停留多久
    static let doneAnim: TimeInterval = 0.30   // 补到 100% 的时长

    /// checking 变化：true 开始、false 完成。跟菜单动画完全同一个源。
    func update(checking now: Bool) {
        if now, started == nil || finishedAt != nil {
            // 新一轮开始：清掉上一轮残留
            started = Date()
            finishedAt = nil
            finishFrom = 0
        } else if !now, let started, finishedAt == nil {
            // 菜单停了 = 真实检测结束：记下当前进度，接下来补到 100%
            // 用和 progress() 同一个公式，别让完成瞬间进度跳一下
            finishFrom = Self.running(elapsed: max(Date().timeIntervalSince(started), 0))
            finishedAt = Date()
            let gen = self.started
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doneHold) { [weak self] in
                guard let self, self.started == gen else { return }
                self.started = nil
                self.finishedAt = nil
                self.finishFrom = 0
            }
        }
    }

    /// 纯函数：进度由时间决定。未完成时平缓爬到 90%（不到顶）；
    /// 完成后从 finishFrom 平滑补到 100%。返回恒定在 0...1，绝不超过 100%。
    func progress(at now: Date) -> CGFloat {
        guard let started = started else { return 0 }
        return Self.value(at: now, started: started,
                          finishedAt: finishedAt, from: finishFrom)
    }

    private static func value(at now: Date, started: Date,
                              finishedAt: Date?, from: CGFloat) -> CGFloat {
        if let finishedAt {
            let t = min(max(now.timeIntervalSince(finishedAt) / doneAnim, 0), 1)
            return min(1, from + (1 - from) * CGFloat(easeOut(t)))
        }
        return Self.running(elapsed: max(now.timeIntervalSince(started), 0))
    }

    /// 扫描中那段：线性、6 秒爬到 90%。真实全量检测 5~7 秒（菜单栏图标
    /// 转 5~6 圈），进度条跟着这个节奏匀速走，观感才不会「扫一下就完了」。
    /// 别用 1-exp(-t/2.2) 或 easeOut(t/4) —— 前两秒就冲到七八成，看着太快。
    /// 完成态的起点也走这里，保证 checking 归零那一刻进度不跳变。
    private static func running(elapsed: TimeInterval) -> CGFloat {
        return 0.90 * CGFloat(min(elapsed / 6.0, 1))
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

/// 按下反馈：把 isPressed 写回 phase，让胶囊底色和缩放跟手势一致。
private struct ScanPressStyle: ButtonStyle {
    var phase: ScanPhase
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { phase.pressed = $0 }
    }
}

/// 底栏「重新扫描」胶囊 —— 最基本的进度条，且和菜单栏图标严格同步：
///  · 空闲：虚线圆环 + 「重新扫描」，hover 底色变亮、按下底色再亮一点；
///  · 扫描中：checking=true（菜单在转）时蓝条从左平缓铺、数字跟着涨，
///    两者用同一个 p；符号始终是同一个圆环，被蓝条盖住时由深转白；
///  · 完成：checking=false（菜单停）立刻补到 100%，短暂停留后回空闲。
private struct ScanCapsule: View {
    let checking: Bool
    let width: CGFloat
    let hover: HoverBox
    let action: () -> Void

    // 必须是 @StateObject：用 @ObservedObject + 默认初始值的话，ContentView.body 每次
    // 因 results/progress/rows 变化重算时，这个子视图会被重建、phase 被换成 started=nil
    // 的新实例，进度条当场清零 —— 表现为「点了扫描却完全没有进度」。@StateObject 由
    // SwiftUI 稳定持有同一个实例，跨重建保住 started / finishedAt。
    @StateObject private var phase = ScanPhase()
    private static let height: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            // 同一个 p 同时喂给蓝条、数字、遮罩，三者永远一致；clamp 防止越界
            let raw = phase.progress(at: timeline.date)
            let p = min(max(raw, 0), 1)
            let done = phase.finishedAt != nil
            let label = done ? "100%" : (p > 0 ? "\(Int(p * 100))%" : "重新扫描")

            Button {
                guard !checking else { return }
                action()
            } label: {
                ZStack(alignment: .leading) {
                    // 明确的状态底色：空闲淡、hover 亮、按下更亮
                    Capsule()
                        .fill(Color.primary.opacity(
                            phase.pressed ? 0.18 : (hover.on ? 0.12 : 0.06)))
                        .animation(.easeOut(duration: 0.10), value: hover.on)
                        .animation(.easeOut(duration: 0.08), value: phase.pressed)

                    // 蓝条：画一条和按钮完全同尺寸的整条胶囊，再用左对齐的矩形
                    // 遮罩裁出左边 p 那一段。绝不「画一条宽度=p 的胶囊」——那样
                    // p 很小时宽度小于高度，胶囊会缩成一个圆顶出上下边框，右端
                    // 也跟着变圆，看起来就是蓝块超出按钮边框。整条胶囊 + 裁剪后，
                    // 右端始终是圆头、上下永远贴着按钮边，低百分比也不会冒出去。
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: width, height: Self.height)
                        .mask(alignment: .leading) {
                            GeometryReader { g in
                                Rectangle()
                                    .frame(width: g.size.width * p, height: g.size.height)
                            }
                        }
                        .animation(nil, value: p)

                    // 内容两遍：深色打底 + 白色用同一块蓝条遮罩，视觉与进度一致
                    capsuleContent(label: label)
                        .foregroundStyle(Color.primary)
                    capsuleContent(label: label)
                        .foregroundStyle(Color.white)
                        .mask(alignment: .leading) {
                            GeometryReader { g in
                                Rectangle()
                                    .frame(width: g.size.width * p, height: g.size.height)
                            }
                        }
                }
                .frame(width: width, height: Self.height)
                .scaleEffect(phase.pressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.08), value: phase.pressed)
            }
            .buttonStyle(ScanPressStyle(phase: phase))
            .contentShape(Capsule())
            .frame(width: width, height: Self.height)
        }
        .onAppear { phase.update(checking: checking) }
        .onHover { hover.on = $0 }
        .onChange(of: checking) { phase.update(checking: $0) }
        .modifier(ScanGlassCapsule())
    }

    @ViewBuilder
    private func capsuleContent(label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 11, weight: .medium))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .frame(width: width, height: Self.height)
    }
}

/// 顶部页签：整条是系统的液态玻璃（glassEffect），悬停/选中胶囊是我们自绘的中性色
private struct GlassTrack: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

/// 两格在轨道里的位置，用偏好值从子视图传上来
private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 选中胶囊：位置和宽度直接作为 Shape 的 animatableData 插值。
/// 之前是 Capsule().frame().offset()——改宽高等于改布局，胶囊滑动的每一帧
/// 都要重新走一遍布局，压在液态玻璃上就掉帧。改成路径插值后只重画这一个形状。
private struct PillRect: Shape {
    var rect: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(rect.minX, rect.minY), .init(rect.width, rect.height)) }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in bounds: CGRect) -> Path {
        Path(roundedRect: rect.offsetBy(dx: bounds.minX, dy: bounds.minY),
             cornerRadius: rect.height / 2, style: .continuous)
    }
}

/// 系统自己的不确定进度指示器（NSProgressIndicator 的 spinning 样式）。
/// 之前是想让箭头符号自己转：可箭头是方块状的字形，转起来按对角线扫，
/// 角尖必然扫出圆框；缩小字号又跟旁边的齿轮不一样大。转圈这件事交给系统，
/// 尺寸、转速、透明度（包括"降低动态效果"）都由它按自身设置来。
private struct NativeSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {}
}

/// 圆形玻璃按钮（刷新 / 设置齿轮用）：跟分段控件、搜索框同一套材质
/// 圆形按钮（底栏关于 / 设置 / 退出）：用系统的玻璃按钮样式，悬停明暗由系统给
private struct GlassCircleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

/// 胶囊按钮（扫描 / 返回）：用系统的玻璃按钮样式，悬停明暗由系统给
private struct GlassCapsuleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

/// 圆角玻璃卡片（「最近搜索」浮层用）：跟搜索框同一个材质，形状换成矩形圆角
private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

/// 搜索态下「点这里不算点别处」的两块地方（窗口坐标）：搜索胶囊 + 最近搜索浮层。
/// 布局一变就由 WindowRectReporter 刷新，本地鼠标监听器读它。
/// 只存矩形、不发通知：它一变就重绘会把整条顶栏带进去。
final class SearchHitAreas {
    static let shared = SearchHitAreas()
    var bar: CGRect?
    var recent: CGRect?

    /// 边缘各自外扩一点：圆角那几像素、玻璃外沿的一点点误差不该判成「点别处」
    func contains(_ point: NSPoint) -> Bool {
        if let bar, bar.insetBy(dx: -3, dy: -3).contains(point) { return true }
        if let recent, recent.insetBy(dx: -3, dy: -3).contains(point) { return true }
        return false
    }
}

/// 一块区域的窗口坐标上报器：只量位置，不参与命中（hitTest 直接返回 nil）。
private struct WindowRectReporter: NSViewRepresentable {
    let onChange: (CGRect?) -> Void

    final class Probe: NSView {
        var onChange: ((CGRect?) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }
        override func layout() {
            super.layout()
            report()
        }
        func report() {
            guard window != nil, superview != nil else { onChange?(nil); return }
            onChange?(convert(bounds, to: nil))
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
        probe.report()
    }
}

/// 搜索输入框包成 NSTextField，是为了两件 SwiftUI 做不到的事：
/// 1) placeholder 的字号——SwiftUI 的 TextField 会把「搜索」按系统 13 号画，跟左边 11.5 号的分段不一致；
/// 2) 中文输入法打字时，SwiftUI 的 binding 要等选字/回车才更新，自己画的占位文字就会一直压在拼音上面。
///    包成 AppKit 之后 placeholder 由系统管，一有字（包括还没上屏的拼音）就消失。
private struct SearchField: NSViewRepresentable {
    let ui: UIState

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var focusObserver: NSObjectProtocol?
        var setObserver: NSObjectProtocol?
        /// 点面板里别处就收起搜索态的监听器（只在输入框活着的时候挂着）
        private var mouseMonitor: Any?
        init(_ parent: SearchField) { self.parent = parent }

        /// 为什么用本地鼠标监听器，而不是在面板上垫一层透明手势：
        /// 面板里能点的地方五花八门（分段、行、行内按钮、底栏），垫一层手势会把
        /// 这些点击全吃掉，变成「点两下才生效」。监听器只看位置，不拦事件。
        func installMouseMonitor(for field: NSTextField) {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self, weak field] event in
                guard let self, let field, let window = field.window,
                      event.window === window          // 别的窗口（比如菜单弹层）不归这里管
                else { return event }
                let point = event.locationInWindow
                if SearchHitAreas.shared.contains(point) { return event }
                // 探针还没报上坐标（刚建出来的那一两帧）：退回用输入框自己的框，
                // 左右各放宽到整条胶囊（放大镜和清除钮都在里面）
                if SearchHitAreas.shared.bar == nil {
                    let fallback = field.convert(field.bounds, to: nil).insetBy(dx: -22, dy: -6)
                    if fallback.contains(point) { return event }
                }
                self.collapse(field)
                return event
            }
        }

        /// 收起搜索态。先摘第一响应者再改状态 —— 跟 Esc 那条路同一个坑：
        /// 直接让 SwiftUI 把输入框从视图树里摘掉的话，NSTextField 还处在编辑中，光标会飘。
        /// 不动 query：只是把输入框收起来，筛过的列表保持原样，搜索图标会染色提示。
        func collapse(_ field: NSTextField) {
            guard parent.ui.searchActive else { return }
            field.window?.makeFirstResponder(nil)
            parent.ui.searchActive = false
        }

        deinit {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // 中文输入法还没上屏时，marked text 在 field editor 里，field.stringValue 还是空的；
            // 读编辑器的 string 才能跟着拼音实时过滤，而不是等回车。
            let editor = field.currentEditor() as? NSTextView
            parent.ui.query = editor?.string ?? field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.ui.searchActive = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // 延一小会儿再收起「最近搜索」：单击是 按下→抬起 两段，
            // 第一下就已经结束编辑了，立刻收掉的话抬起的动作落在空处，那一行就点不中。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let field = obj.object as? NSTextField
                if field?.currentEditor() == nil { self.parent.ui.searchActive = false }
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // 回车＝这次搜索告一段落，记进最近搜索；吃掉回车，别让系统响一声
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.ui.commitSearch(textView.string.isEmpty ? parent.ui.query : textView.string)
                return true
            }
            // Esc＝退出搜索态，退回顶栏那两颗按钮。
            // 先卸掉第一响应者再改状态：直接让 SwiftUI 把输入框从视图树里摘掉，
            // NSTextField 还处在编辑中，光标会飘到别的地方去。
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                parent.ui.applySearch("")
                parent.ui.searchActive = false
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        // 收起时不清查筛选词：再点开搜索，框里得还是原来那个词（不然列表筛着、框却是空的）
        field.stringValue = ui.query
        field.font = .systemFont(ofSize: 11.5)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "搜索",
            attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        field.delegate = context.coordinator
        // 点面板里别处 → 自动收起（见 Coordinator.installMouseMonitor）
        context.coordinator.installMouseMonitor(for: field)
        // ⌘F 聚焦：面板由 AppDelegate 弹出后发通知，这里接住并把光标放进搜索框
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(
            forName: .updateRadarFocusSearch, object: nil, queue: .main
        ) { [weak field] _ in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        // 外部改写内容（清除按钮、点最近搜索里的一条）：连编辑器一起改，否则界面会两套字
        context.coordinator.setObserver = NotificationCenter.default.addObserver(
            forName: .updateRadarSetSearch, object: nil, queue: .main
        ) { [weak field] note in
            guard let field, let window = field.window else { return }
            let word = (note.object as? String) ?? ""
            field.stringValue = word
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = word
                editor.setSelectedRange(NSRange(location: word.count, length: 0))
            }
        }
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if let token = coordinator.focusObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = coordinator.setObserver {
            NotificationCenter.default.removeObserver(token)
        }
        // 输入框没了，报告出来的两块区域作废，免得下一轮点到旧位置还算「在搜索区里」
        SearchHitAreas.shared.bar = nil
        SearchHitAreas.shared.recent = nil
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 只在外部真的改了内容时回写，别在用户打字（尤其拼音还没上屏）时去重置它
        if field.stringValue != ui.query, field.currentEditor() == nil {
            field.stringValue = ui.query
        }
    }
}

private struct GlassSearchField: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

// MARK: - 单行

/// 无边框按钮：按下时压暗一点点并轻微缩小，胶囊才有「按到了」的反馈
private struct PressablePlainButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.10 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// 图标交给 AppKit 自己画：缓存里那张图带浅色/深色两份表示，
/// 系统换外观时这个 NSView 会收到回调重绘，AppKit 按当前外观挑对应那份。
/// 之前用 SwiftUI 的 Image + colorScheme 取图，面板这套自建窗口里 body
/// 不随外观重算，图标就一直停着，非要重启才换。
private struct AppIcon: NSViewRepresentable {
    let icons: AppIconPair

    func makeNSView(context: Context) -> IconView {
        let view = IconView()
        view.icons = icons
        return view
    }

    func updateNSView(_ nsView: IconView, context: Context) {
        nsView.icons = icons
    }

    final class IconView: NSView {
        var icons: AppIconPair? {
            didSet { needsDisplay = true }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let icons else { return }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? icons.dark : icons.light).draw(in: bounds, from: .zero,
                                                   operation: .sourceOver, fraction: 1,
                                                   respectFlipped: true,
                                                   hints: [.interpolation: NSImageInterpolation.high])
        }

        // 别挡住行里的点击
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 展开说明里「展开全部 / 收起」的状态。
/// 这台机器只有 Command Line Tools，SwiftUI 的宏插件没有，`@State` 编不过，
/// 所以跟 HoverBox 一样走一个小 ObservableObject，按 App id 记。
final class NotesBox: ObservableObject {
    static let shared = NotesBox()

    /// 点过「展开全部」的行
    @Published private(set) var expanded: Set<String> = []

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    func toggle(_ key: String) {
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }

    /// 行收起来时清干净：下次点开还是先看 8 行摘要
    func forget(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) }
    }
}

/// 每行说明文字的自然高度：只用来判断要不要给「展开全部」。
/// 量到之后只通知**本行**重绘一次；不放进 NotesBox 单例（一发布会让所有行
/// 重排，近百行滚动时能卡半秒），也不用 @State（本机缺 SwiftUI 宏插件，编不过）。
final class RowMeasure: ObservableObject {
    @Published private(set) var natural: CGFloat = 0

    func set(_ h: CGFloat) {
        // 同值不发布：量高只会触发一次重绘，不会来回抖成无限循环
        if abs(natural - h) > 0.5 { natural = h }
    }

    /// List 会复用行视图：换了一个 App 就清掉上一个 App 的测量值
    func reset() {
        if natural != 0 { natural = 0 }
    }
}

struct RowView: View {
    let row: AppRow
    let service: UpdateService
    @ObservedObject var hover: HoverBox
    /// 「展开全部」的状态（见 NotesBox 的说明）
    @ObservedObject private var notes = NotesBox.shared
    /// 本行说明文字的自然高度：量到后只重绘这一行，用来决定要不要给「展开全部」
    @StateObject private var measure = RowMeasure()
    /// 这一行的锚点名字：整页的高亮条靠它找到这一行的窗口坐标
    var anchorKey: String = ""
    var ignored: Bool = false
    /// 更新说明展开着没
    var expanded: Bool = false
    /// 行底要不要画分隔线（最后一行不画）
    var showsDivider: Bool = false
    var onToggle: () -> Void = {}
    /// 把自己在列表里的位置报给 UIState，键盘 ↑↓ 按它排序（见 moveKeyRow）
    var onFrame: (CGRect) -> Void = { _ in }

    var body: some View {
        rowContent
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // 左半：图标 + 名字 + 版本 + 空白。点这片 = 展开/收起更新说明。
                // 这里用 onTapGesture 而不是 Button：Button 在 List 行里要建整套控件、
                // 焦点和悬停跟踪，近百行滚动时每新露出一行都要付一遍，实测单这一项
                // 就把滚动尖峰从 60ms 抬到 150ms。点击行为不变，无障碍用
                // accessibilityAction 补回来，VoiceOver 照样能「按」这一行。
                HStack(alignment: .center, spacing: 10) {
                    AppIcon(icons: row.app.icon)
                        .frame(width: PanelMetrics.iconSide, height: PanelMetrics.iconSide)

                    VStack(alignment: .leading, spacing: 1) {
                        // 字重跟系统菜单一致：正文普通体，不额外加粗
                        Text(row.app.name)
                            .font(.body)
                            .foregroundStyle(hover.on ? Color.white : Color.primary)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(hover.on ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
                // 直接给 label，不走 children: .combine：combine 每次构建都要
                // 遍历合并子树，近百行滚动时每新露一行都付一遍
                .accessibilityElement()
                .accessibilityLabel("\(row.app.name)，\(row.subtitle)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onToggle() }

                // 右半：状态字 / 「更新」
                if ignored {
                    Text("已忽略")
                        .font(.footnote)
                        .foregroundStyle(hover.on ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                        .contentShape(Rectangle())
                        .onTapGesture { onToggle() }
                } else if row.isUpdate {
                    // 「更新」内部也已是点击手势（见 trailingContent），不再是 Button
                    trailing
                } else {
                    // 已是最新 / 检测失败 / 无检测源：这几个只是字，点一下也能展开说明
                    trailing
                        .contentShape(Rectangle())
                        .onTapGesture { onToggle() }
                }
            }
            // 头部这一行自己留上下 3pt 呼吸，不靠外层的 .frame(minHeight:46) 居中。
            // 原来收起时外层把 40pt 图标居中在 46pt 行里（图标离行顶 3pt），展开后
            // 内容超过 46pt 就不再居中，图标直接贴到行顶 —— 蓝框没动、图标上移 3pt，
            // 看着就是「展开简介后预选框离图标更近」。两种状态都显式留 3pt 就一致了。
            .padding(.vertical, PanelMetrics.rowVerticalPadding)

            // 更新说明：点开整块出现、收起整块消失，不做补间动画。
            // List（NSTableView）的行高本来就是一帧到位，硬加逐帧长高反而跟
            // 列表里其他即时交互（切页签、换行、展开全部）不统一。
            // 收起的行不建这一块：说明文字（几百字、可选中）是整行最贵的东西，
            // 近百行滚动时每露一行都排一遍字，正是「其他」页卡顿的来源。
            if expanded {
                notesBlock
                    // 可选中只在真正显示时挂：这是行里最贵的部件
                    .textSelection(.enabled)
            }
        }
        // 左右必须一样宽：之前右边多留 10pt 是为了躲滚动条，结果图标离左边 20pt、
        // 「更新」按钮离右边 23pt，看着就是歪的。外层的 8pt 已经够让滚动条错开了。
        .padding(.horizontal, 4)
        // 收起行给**固定**高度 46：List 背后是 NSTableView，行高固定时它能走
        // 「统一行高」的快速虚拟化路径，不用为每个新露出的行测量内容高度；
        // 之前用 minHeight，每行都要量一次，近百行滚动时就是那些 100ms+ 的尖峰。
        // 展开的那一行仍然让它自己撑高（一次只有一行展开，量一次无所谓）。
        .frame(height: expanded ? nil : PanelMetrics.rowHeight)
        // 报位置给键盘 ↑↓ 排序（点简介时的自动滚动已删，不再用它判断要不要滚）。
        // 高亮条用下面这个 AppKit 锚点定位，不依赖这里的 SwiftUI 坐标。
        .background {
            GeometryReader { g in
                Color.clear
                    .onChange(of: g.frame(in: .named("urList")), initial: true) { _, rect in
                        onFrame(rect)
                    }
            }
        }
        // 给高亮条定位的是这个 AppKit 锚点：它报的是窗口坐标，不经过 SwiftUI 的
        // 布局/滚动，行滚到哪它就在哪，不会被 List 的内边距带偏
        .background {
            RowAnchor(anchorKey: anchorKey, box: hover)
        }
        // 悬停的蓝底不画在行里，改成整页共用一块会滑动的（见 HoverBarView）：
        // 行里只留展开说明的淡底。
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.12))
                .opacity(expanded && !hover.on ? 1 : 0)
                .padding(.vertical, 1)
        }
        .contentShape(Rectangle())
        // 文字转白跟着高亮条同一条弹簧走，整行是一起「漫」过去的
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: hover.on)

        // 行收起来之后，「展开全部」也回到折叠态：下次点开这一行还是先看 8 行摘要，
        // 不会是上次留着的整段长文。顺带把量到的高度清掉，换个 App 复用这一行时重新量。
        .onChange(of: expanded) { _, now in
            if !now { notes.forget(row.app.id) }
        }
        // List 会复用行视图：换了一个 App 就必须清掉上一个 App 的测量值，
        // 否则一颗只有三行说明的行会继承上一行的一千字高度，白给一个「展开全部」
        .onChange(of: row.app.id) { _, _ in
            notes.forget(row.app.id)
            measure.reset()
        }

        // 分隔线：跟 App Store 的「最近更新」一致，从图标左边缘起、到内容右边缘止，
        // 也就是和整行的内容区同宽，不是对齐到文字。
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
                    // 跟整行内容的左右内边距一致，两头一样齐
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        // 右键菜单不在这里挂：SwiftUI 的 .contextMenu 挂在 List 行上时，系统会给那一行
        // 画一层通栏直角的高亮，和我们 12pt 圆角的行底叠在一起就多出一个方框。
        // 菜单改由 RowMenuMonitor 用 AppKit 弹（见文件下方的实现）。
    }

    // MARK: - 展开后的更新说明

    /// 更新说明常是「A • B • C」一长串，展开时按 • 断行，读起来才像一份说明
    private var noteLines: [String] {
        guard let notes = row.result?.notes else { return [] }
        let bullet = notes.replacingOccurrences(of: "•", with: "\n• ")
        let lines = bullet
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "•" }
        return lines.isEmpty ? [notes] : lines
    }

    /// 折叠时露出多少说明：8 行。footnote 在 macOS 上一行约 16pt（字 12 + 行距），
    /// 断行是按 • 分的段，段内还会自己折行，所以这里量的是「像素高度」不是「条数」。
    private var notesPreviewHeight: CGFloat { 8 * 16 }

    private var notesExpanded: Bool { notes.isExpanded(row.app.id) }

    /// 自然高度超过预览高度才算「长说明」，要给它「展开全部」。
    /// 高度记在本行自己的 RowMeasure 上：量到后只重绘这一行，
    /// 不放全局字典、不发布给所有行，近百行滚动时才不会卡那 0.5s。
    private var notesIsLong: Bool { measure.natural > notesPreviewHeight + 2 }

    /// 说明本体：抽出来是为了能在它身上挂「先量高、再裁剪」的修饰符
    @ViewBuilder
    private var noteText: some View {
        if noteLines.isEmpty {
            Text("这个 App 的更新源没带更新说明")
                .font(.footnote)
                .foregroundStyle(hover.on ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(noteLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(hover.on ? Color.white.opacity(0.85) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            noteText
                // 先量自然高度（量在裁剪之前）：只有没被压扁的时候才知道它到底多长。
                // 量到后只通知本行重绘一次，「展开全部」按钮据此决定要不要出现
                .background {
                    GeometryReader { g in
                        Color.clear
                            .onChange(of: g.size.height, initial: true) { _, h in
                                measure.set(h)
                            }
                    }
                }
                // 折叠态压到 8 行高。Permute 那种源给的是一千多字一整段、
                // 既没有 • 也没有换行，不压一下展开就把整个列表顶出屏幕。
                .frame(maxHeight: notesExpanded ? nil : notesPreviewHeight, alignment: .top)
                .clipped()
                // 折叠时底部淡出，别让最后一行被一刀切成半截字
                .mask(alignment: .top) {
                    if notesIsLong && !notesExpanded {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0),
                                    .init(color: .black, location: 1 - 20 / notesPreviewHeight),
                                    .init(color: .clear, location: 1)],
                            startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle().fill(Color.black)
                    }
                }

            if notesIsLong {
                textButton(notesExpanded ? "收起" : "展开全部") {
                    notes.toggle(row.app.id)
                }
            }

            // 去处放最下面：先读这次更新了什么，再决定要不要点进去。
            // 「在 Finder 中显示」去掉了：右键菜单里本来就有，不用占一行位置。
            // 两个链接都没有的（检测失败这类）整行不画，否则会留一条空的间距。
            // 往右缩进 8pt：这一行在行底，左边正是高亮条 12pt 圆角的位置，
            // 贴着左边缘的话「打」字会被圆弧切掉一角。
            if row.result?.downloadURL != nil || row.result?.homepage != nil {
                HStack(spacing: 12) {
                    if row.result?.downloadURL != nil {
                        textButton("打开下载页") { service.openUpdate(for: row) }
                    }
                    if row.result?.homepage != nil {
                        textButton("官网") { service.openSite(for: row) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
            }
        }
        .padding(.top, 2)
        // 底部留白：高亮条是照着整行画的，内容贴到边上线上的圆角就会切到字。
        // 5pt 刚好让最后一行字（链接行）离高亮条底边的圆弧有一段距离。
        .padding(.bottom, 5)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                // 悬停时整行是强调蓝，链接再用强调色就看不见了，转白字
                .foregroundStyle(hover.on ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// 状态字只有这一处定义：行尾的「已是最新版本」「检测失败」都走它
    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            // 跟名字旁边那行版本号一样用系统的次要色：深色下是白、浅色下是黑，
            // 不再写死半透明白（浅色面板上那行字几乎看不见）
            .foregroundStyle(hover.on ? Color.white : Color.secondary)
    }

    /// 右侧这一列统一 82pt 宽、居中：「更新」「已是最新版本」「检测失败」的中线
    /// 都压在搜索框的中线上，不会各行右对齐得参差不齐。
    private var trailing: some View {
        trailingContent
            .frame(width: 82, alignment: .center)
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch row.status {
        case .updateAvailable:
            // 照系统菜单的做法：右侧那一列（快捷键 / 取值）在未高亮时是「次要色」，
            // 高亮后才提到纯白。次要色跟着明暗模式走，浅色面板下是黑、深色下是白。
            // 用点击手势而不是 Button：Button 在 List 行里要建整套控件、焦点链、
            // 悬停跟踪，近百行滚动时每新露出一行都要付一遍，这是滚动尖峰的大头。
            // 这是个真操作（打开下载页），无障碍用 isButton + action 补回来。
            Text("更新")
                .font(.subheadline)
                .foregroundStyle(hover.on ? Color.white : Color.secondary)
                .padding(.vertical, 4.5)
                .contentShape(Rectangle())
                .onTapGesture { service.openUpdate(for: row) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { service.openUpdate(for: row) }
        case .upToDate:
            // 行尾照旧写「已是最新版本」；页签里的分组标题不再重复这句话
            statusText("已是最新版本")
        case .failed:
            // 图标在前、字在后。图标沿用之前那一版：9pt 三角、不额外偏移。
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .imageScale(.small)
                    .foregroundStyle(warnAmber)
                statusText("检测失败")
            }
            // 为什么失败：副标题只放得下一句短的，完整原文（限流、超时…）放悬停提示
        case .unknown:
            Text("无检测源")
                .font(.caption2)
                .foregroundStyle(hover.on ? Color.white : Color.secondary)
        }
    }
}

/// 「关于」页的图标：跟设置行同一个尺寸和底色
private struct AboutIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.75))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.primary.opacity(0.05)))
    }
}

/// 「关于」页的信息行：图标 + 标题 + 右侧只读值
private struct AboutValueRow: View {
    let symbol: String
    let title: String
    let value: String
    var showDivider = true

    var body: some View {
        HStack(spacing: 9) {
            AboutIcon(symbol: symbol)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showDivider { RowDivider() }
        }
    }
}

/// 「关于」页的操作行：图标 + 标题 + 右侧控件（检查更新 / 安装按钮）
private struct AboutControlRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var showDivider = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 9) {
            AboutIcon(symbol: symbol)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showDivider { RowDivider() }
        }
    }
}

/// 「关于」页的反馈行：整行可点，右侧值 + 小箭头
private struct AboutLinkRow: View {
    let symbol: String
    let title: String
    var value: String? = nil
    var showDivider = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AboutIcon(symbol: symbol)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                if let value {
                    Text(value)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                if showDivider { RowDivider() }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 29)
    }
}

// MARK: - 行右键菜单（AppKit）

/// 右键菜单的每个条目存一个闭包。NSMenuItem 的 target 是弱引用，
/// 得有个对象在菜单弹出期间活着，闭包才不会丢。
final class MenuHandler: NSObject {
    private var actions: [() -> Void] = []

    func reset() { actions.removeAll() }

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count - 1
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// 自己接右键、自己弹 NSMenu。
/// 不用 SwiftUI 的 .contextMenu，是因为它挂在 List 行上时，系统会给那一行再画一层
/// 通栏直角的高亮块，和行底的 12pt 圆角叠在一起就多出一个方框。
private struct RowMenuMonitor: NSViewRepresentable {
    let active: () -> Bool
    let hoveredRow: () -> AppRow?
    let buildMenu: (AppRow, MenuHandler) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, active: active,
                                    hoveredRow: hoveredRow, buildMenu: buildMenu)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(view: nsView, active: active,
                                   hoveredRow: hoveredRow, buildMenu: buildMenu)
    }

    final class Coordinator {
        private weak var host: NSView?
        private var active: () -> Bool = { false }
        private var hoveredRow: () -> AppRow? = { nil }
        private var buildMenu: (AppRow, MenuHandler) -> NSMenu = { _, _ in NSMenu() }
        private let handler = MenuHandler()
        private var monitor: Any?

        func install(view: NSView, active: @escaping () -> Bool,
                     hoveredRow: @escaping () -> AppRow?,
                     buildMenu: @escaping (AppRow, MenuHandler) -> NSMenu) {
            update(view: view, active: active, hoveredRow: hoveredRow, buildMenu: buildMenu)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self,
                      self.active(),
                      event.window?.isVisible == true,
                      let host = self.host,
                      let row = self.hoveredRow()
                else { return event }
                let menu = self.buildMenu(row, self.handler)
                menu.popUp(positioning: nil,
                           at: host.convert(event.locationInWindow, from: nil),
                           in: host)
                return nil
            }
        }

        func update(view: NSView, active: @escaping () -> Bool,
                    hoveredRow: @escaping () -> AppRow?,
                    buildMenu: @escaping (AppRow, MenuHandler) -> NSMenu) {
            host = view
            self.active = active
            self.hoveredRow = hoveredRow
            self.buildMenu = buildMenu
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

