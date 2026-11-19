import AppKit
import Foundation

/// 一条要一起清掉的残留
struct ResidualItem: Identifiable {
    let id: String          // 绝对路径
    let url: URL
    let label: String       // 相对 ~ 的路径，显示用
    var selected: Bool
    /// 同开发者的几个 App 可能共用（Group Containers）→ 默认不勾
    let shared: Bool
}

struct UninstallPlan {
    let app: InstalledApp
    let appURL: URL
    var residuals: [ResidualItem]
}

/// 卸载：App 本体 + 勾选的残留，全部走「移到废纸篓」，误删能捞回来。
enum Uninstaller {

    // MARK: - 扫描残留

    static func plan(for app: InstalledApp) -> UninstallPlan {
        let appURL = URL(fileURLWithPath: app.path)
        var items: [ResidualItem] = []
        guard let bid = app.bundleId, !bid.isEmpty else {
            return UninstallPlan(app: app, appURL: appURL, residuals: items)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        let fm = FileManager.default

        /// 只加真实存在的路径
        func add(_ url: URL, shared: Bool = false) {
            guard fm.fileExists(atPath: url.path) else { return }
            let label = url.path.hasPrefix(home.path + "/")
                ? String(url.path.dropFirst(home.path.count + 1))
                : url.path
            items.append(ResidualItem(id: url.path, url: url, label: label,
                                      selected: !shared, shared: shared))
        }

        add(lib.appendingPathComponent("Application Support/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("Caches/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("Preferences/\(bid).plist"))
        add(lib.appendingPathComponent("Saved Application State/\(bid).savedState", isDirectory: true))
        add(lib.appendingPathComponent("Containers/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("HTTPStorages/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("WebKit/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("Application Scripts/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("Logs/\(bid)", isDirectory: true))
        add(lib.appendingPathComponent("LaunchAgents/\(bid).plist"))

        // Group Containers 的目录名是 TEAMID.组名，经常被同开发者的多个 App 共用，
        // 默认不勾，让用户自己决定
        let groupDir = lib.appendingPathComponent("Group Containers", isDirectory: true)
        if let subs = try? fm.contentsOfDirectory(at: groupDir, includingPropertiesForKeys: nil) {
            for url in subs {
                let name = url.lastPathComponent
                if name == bid || name.hasSuffix("." + bid) {
                    add(url, shared: true)
                }
            }
        }
        return UninstallPlan(app: app, appURL: appURL, residuals: items)
    }

    /// 系统目录里的 App、以及「自己」都不给卸载入口
    static func canUninstall(_ app: InstalledApp) -> Bool {
        if app.path.hasPrefix("/System/") { return false }
        if app.path == Bundle.main.bundlePath { return false }
        if let bid = app.bundleId, bid == Bundle.main.bundleIdentifier { return false }
        return true
    }

    // MARK: - 确认 + 执行

    static func present(for app: InstalledApp, onFinished: @escaping () -> Void) {
        let plan = plan(for: app)
        let alert = NSAlert()
        alert.messageText = "卸载「\(app.name)」？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")

        var boxes: [NSButton] = []
        if plan.residuals.isEmpty {
            alert.informativeText = "\(app.path)\n\n没有找到残留文件。"
        } else {
            alert.informativeText = "\(app.path)\n\n下面这些残留会一起移到废纸篓（之后可以从废纸篓恢复）："
            alert.accessoryView = residualList(plan.residuals, boxes: &boxes)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let chosen = zip(plan.residuals, boxes)
            .filter { $0.1.state == .on }
            .map { $0.0.url }
        // 先退掉正在运行的 App（可能等两三秒），再回主线程做文件操作：
        // 移废纸篓很快，管理员授权要弹系统密码框，都必须在主线程。
        DispatchQueue.global(qos: .userInitiated).async {
            if let bid = app.bundleId { terminate(bundleId: bid) }
            DispatchQueue.main.async {
                let failures = trashAll(appURL: plan.appURL, extras: chosen)
                onFinished()
                report(app: app, failures: failures)
            }
        }
    }

    private static func residualList(_ items: [ResidualItem], boxes: inout [NSButton]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for item in items {
            let title = item.shared ? item.label + "（可能是同开发者的多个 App 共用）" : item.label
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = item.selected ? .on : .off
            box.font = .systemFont(ofSize: 11)
            box.cell?.lineBreakMode = .byTruncatingMiddle
            box.frame.size.width = 372
            boxes.append(box)
            stack.addArrangedSubview(box)
        }
        let width: CGFloat = 380
        let height = min(max(stack.fittingSize.height, 24), 150)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        stack.autoresizingMask = [.width]

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        return scroll
    }

    /// 返回失败的条目说明（空数组＝全部成功）。主线程调用。
    private static func trashAll(appURL: URL, extras: [URL]) -> [String] {
        var failures: [String] = []
        for url in [appURL] + extras {
            // 前面已经删掉（比如残留落在 App 包里）就跳过
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // /Applications 下的包偶尔属主不是当前用户：退回管理员权限删除
                if removeWithAdmin(url) == false {
                    failures.append("\(url.path)：\(error.localizedDescription)")
                }
            }
        }
        return failures
    }

    private static func terminate(bundleId: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !running.isEmpty else { return }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
            usleep(100_000)
        }
        for app in running where !app.isTerminated { app.forceTerminate() }
        usleep(300_000)
    }

    /// 需要授权时弹一次系统密码框。AppleScript 会自己转义路径。
    private static func removeWithAdmin(_ url: URL) -> Bool {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"rm -rf \\\"\(escaped)\\\"\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil && !FileManager.default.fileExists(atPath: url.path)
    }

    private static func report(app: InstalledApp, failures: [String]) {
        let alert = NSAlert()
        if failures.isEmpty {
            alert.messageText = "已卸载「\(app.name)」"
            alert.informativeText = "App 和勾选的残留都已移到废纸篓。"
        } else {
            alert.messageText = "「\(app.name)」没有完全删干净"
            alert.informativeText = failures.joined(separator: "\n")
        }
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
