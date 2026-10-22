import AppKit

struct WinInfo {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: CGRect   // CG 坐标：原点在主屏左上角
}

enum FadeSpeed: String, CaseIterable {
    case demo, fast, normal, slow

    var title: String {
        switch self {
        case .demo: "演示（3 秒后开始，12 秒褪尽）"
        case .fast: "快（15 秒后开始，90 秒褪尽）"
        case .normal: "中（1 分钟后开始，10 分钟褪尽）"
        case .slow: "慢（5 分钟后开始，1 小时褪尽）"
        }
    }

    /// (开始褪色前的宽限, 褪到最浅所需的总时间)，单位秒
    var span: (grace: Double, full: Double) {
        switch self {
        case .demo: (3, 12)
        case .fast: (15, 90)
        case .normal: (60, 600)
        case .slow: (300, 3600)
        }
    }
}

enum FadeStyle: String, CaseIterable {
    case seeThrough, glass, veil

    var title: String {
        switch self {
        case .seeThrough: "透视（越久越透明，能看到窗口后面；需屏幕录制权限）"
        case .glass: "液态玻璃（越久越磨砂，内容逐渐虚化）"
        case .veil: "纯色薄雾"
        }
    }

    /// 液态玻璃需要 macOS 26
    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// 给每个“很久没碰”的窗口盖一层随时间加深的薄雾；鼠标事件会穿透雾，点一下窗口就恢复
final class Fader {
    static let maxAlpha: CGFloat = 0.74

    private var lastFocus: [CGWindowID: Date] = [:]
    private var overlays: [CGWindowID: NSWindow] = [:]
    private var timer: Timer?
    private(set) var snapshot: [WinInfo] = []

    var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "paused") }
        set { UserDefaults.standard.set(newValue, forKey: "paused"); if newValue { clearOverlays() } }
    }

    var speed: FadeSpeed {
        get { FadeSpeed(rawValue: UserDefaults.standard.string(forKey: "speed") ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speed") }
    }

    /// 用户选的外观
    var style: FadeStyle {
        get {
            let saved = FadeStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .glass
            return saved == .glass && !FadeStyle.glassAvailable ? .veil : saved
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style") }
    }

    /// 实际生效的外观：选了透视但还没授权屏幕录制时，先用玻璃（或薄雾）顶着
    var effectiveStyle: FadeStyle {
        if style == .seeThrough, !SeeThrough.hasPermission { return FadeStyle.glassAvailable ? .glass : .veil }
        return style
    }

    private var overlayStyle: FadeStyle?
    private lazy var seeThrough: SeeThrough = MainActor.assumeIsolated { SeeThrough() }

    /// 每个窗口“应该”褪到多少（0...1，按闲置时间算），和“现在画出来”是多少；动画让后者平滑追上前者
    private var targets: [CGWindowID: CGFloat] = [:]
    private var shown: [CGWindowID: CGFloat] = [:]
    private var animTimer: Timer?
    private var lastAnim = Date()

    /// 窗口在动（拖动、显示桌面时一起滑开）时雾层先藏起来，停稳了再淡回来；vis 就是这个“显现度”
    private var lastMoved: [CGWindowID: Date] = [:]
    private var vis: [CGWindowID: CGFloat] = [:]
    private var settled: [CGWindowID: Bool] = [:]
    private var captureBounds: [CGWindowID: CGRect] = [:]
    static let settleDelay: TimeInterval = 0.35

    /// 透视时窗口最多透明到这里，保留一点影子，免得彻底看不见
    static let maxSeeThrough: CGFloat = 0.72

    func start() {
        // 窗口列表 30 次/秒，好尽早发现窗口在动；动画 60 帧/秒，只改透明度，开销很小
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let a = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.animate() }
        RunLoop.main.add(a, forMode: .common)
        animTimer = a

        // 点下去的那一刻就把雾层提到最上面，赶在窗口被系统提到前台之前；
        // 否则窗口会先盖住雾层（一下变清晰），下一次轮询雾层又盖回来（一下变模糊），就是闪
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.mouseDown() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.poll() }
    }

    private func mouseDown() {
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        let pt = CGPoint(x: p.x, y: h - p.y)
        guard let w = snapshot.first(where: { $0.bounds.contains(pt) }), let win = overlays[w.id], (shown[w.id] ?? 0) > 0.002 else { return }
        lastFocus[w.id] = Date()
        targets[w.id] = 0
        raise(win)
    }

    /// 正在恢复的雾层放到普通窗口之上：它盖着的窗口这时本来就在最前面，所以看起来没区别，但不会被窗口抢到上面
    private func raise(_ win: NSWindow) {
        guard win.level != .floating else { return }
        win.level = .floating
        win.orderFront(nil)
    }

    func idleSeconds(of id: CGWindowID) -> Double {
        lastFocus[id].map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: - 窗口列表

    /// 返回要处理的普通窗口，以及屏幕上所有窗口（含 Dock、菜单栏、我们自己的雾层）从前到后的顺序
    static func onScreenWindows() -> (wins: [WinInfo], order: [CGWindowID]) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
        var out: [WinInfo] = []
        var order: [CGWindowID] = []
        for w in list {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            order.append(id)
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  b.width >= 120, b.height >= 80 else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" { continue }
            out.append(WinInfo(id: id, pid: pid, owner: owner, title: w[kCGWindowName as String] as? String ?? "", bounds: b))
        }
        return (out, order)
    }

    // MARK: - 每 0.1 秒：算目标、跟随窗口位置

    private func poll() {
        guard !paused else { return }
        let (wins, order) = Self.onScreenWindows()
        snapshot = wins
        let now = Date()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 前台 App 最上面的那个窗口算“正在用”
        if let focused = wins.first(where: { $0.pid == frontPid }) { lastFocus[focused.id] = now }
        let alive = Set(wins.map(\.id))
        for w in wins where lastFocus[w.id] == nil { lastFocus[w.id] = now }
        lastFocus = lastFocus.filter { alive.contains($0.key) }
        for (id, win) in overlays where !alive.contains(id) {
            win.orderOut(nil)
            overlays[id] = nil
        }
        targets = targets.filter { alive.contains($0.key) }
        shown = shown.filter { alive.contains($0.key) }
        lastMoved = lastMoved.filter { alive.contains($0.key) }
        vis = vis.filter { alive.contains($0.key) }

        let current = effectiveStyle
        if overlayStyle != current {
            clearOverlays()
            overlayStyle = current
        }

        let (grace, full) = speed.span
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        // 各屏幕在 CG 坐标（左上角原点）里的范围，透视时只处理窗口在屏幕内的部分
        let screensCG = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: screenH - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        var seeTargets: [CGWindowID: (win: WinInfo, view: SeeView, overlay: CGWindowID, frozen: Bool)] = [:]
        let focusedID = wins.first(where: { $0.pid == frontPid })?.id

        for w in wins {
            let idle = now.timeIntervalSince(lastFocus[w.id] ?? now)
            let t = min(max((idle - grace) / (full - grace), 0), 1)
            let target = CGFloat(1 - (1 - t) * (1 - t))   // 先快后慢：刚开始褪就能看出来
            targets[w.id] = target
            // 目标归零后雾层还要留着，等动画把它淡出去再收
            guard target > 0.002 || (shown[w.id] ?? 0) > 0.002 else { continue }

            var b = w.bounds
            if current == .seeThrough {
                let c = CGPoint(x: b.midX, y: b.midY)
                if let scr = screensCG.first(where: { $0.contains(c) }) ?? screensCG.first(where: { $0.intersects(b) }) {
                    b = b.intersection(scr)
                }
                guard !b.isNull, b.width >= 40, b.height >= 40 else { continue }
            }
            let frame = NSRect(x: b.minX, y: screenH - b.maxY, width: b.width, height: b.height)
            let win: NSWindow
            if let o = overlays[w.id] {
                win = o
            } else {
                win = makeOverlay()
                overlays[w.id] = win
                shown[w.id] = 0
                vis[w.id] = 1
                win.alphaValue = 0
            }
            if win.frame != frame {
                if win.frame.width > 0 {
                    // 窗口动了：雾层立刻藏起来，别追着窗口跑
                    lastMoved[w.id] = now
                    vis[w.id] = 0
                    win.alphaValue = 0
                }
                win.setFrame(frame, display: false)
            }
            let moving = now.timeIntervalSince(lastMoved[w.id] ?? .distantPast) < Self.settleDelay
            settled[w.id] = !moving
            captureBounds[w.id] = b
            if w.id == focusedID, target <= 0.002 {
                raise(win)
            } else {
                if win.level != .normal { win.level = .normal }
                // 只在雾层不在窗口正上方时才调整层级，少折腾窗口服务器
                let oi = order.firstIndex(of: CGWindowID(win.windowNumber)), wi = order.firstIndex(of: w.id)
                if oi == nil || wi == nil || oi! + 1 != wi! { win.order(.above, relativeTo: Int(w.id)) }
            }
            if current == .seeThrough, let v = win.contentView as? SeeView {
                let clipped = WinInfo(id: w.id, pid: w.pid, owner: w.owner, title: w.title, bounds: b)
                seeTargets[w.id] = (clipped, v, CGWindowID(win.windowNumber), target <= 0.002 || moving)
            }
        }

        if current == .seeThrough {
            MainActor.assumeIsolated { seeThrough.sync(targets: seeTargets, order: order) }
        }
    }

    // MARK: - 每帧：平滑过渡

    private func animate() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastAnim), 0.1)
        lastAnim = now
        guard !overlays.isEmpty else { return }

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let veil = dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.94, alpha: 1)
        let current = overlayStyle ?? effectiveStyle

        for (id, win) in overlays {
            let target = targets[id] ?? 0
            var s = shown[id] ?? 0
            // 褪色慢慢跟上；回到前台时约 0.3 秒快速恢复
            let rate = target > s ? 2.5 : 10.0
            s += (target - s) * CGFloat(1 - exp(-rate * dt))
            if abs(target - s) < 0.002 { s = target }
            shown[id] = s

            if s <= 0.002, target <= 0.002 {
                win.orderOut(nil)
                overlays[id] = nil
                shown[id] = 0
                continue
            }

            // 停稳之后再淡回来；透视还要等抓取画面对上新位置，不然会先闪一下旧画面
            var ready = settled[id] ?? true
            if ready, current == .seeThrough, let b = captureBounds[id] {
                ready = MainActor.assumeIsolated { seeThrough.isReady(id, bounds: b) }
            }
            var v = vis[id] ?? 1
            if ready {
                v += (1 - v) * CGFloat(1 - exp(-9 * dt))
                if v > 0.995 { v = 1 }
            } else {
                v = 0
            }
            vis[id] = v
            apply(amount: s * v, id: id, style: current, veil: veil, to: win)
        }
    }

    /// amount: 0...1，0 是没褪，1 是褪到最浅
    private func apply(amount: CGFloat, id: CGWindowID, style: FadeStyle, veil: NSColor, to win: NSWindow) {
        if style == .seeThrough, let v = win.contentView as? SeeView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if MainActor.assumeIsolated({ seeThrough.isLive(id) }) {
                // 中间：盖上“窗口后面”的实时画面，按比例变淡，看起来就是窗口本身变透明了
                // 边缘：玻璃边框比中间更早、更实地出现，褪尽之后窗口轮廓依然清楚
                win.alphaValue = 1
                v.layer?.backgroundColor = nil
                v.base.opacity = Float(Self.maxSeeThrough * amount)
                v.rim.opacity = Float(min(1, amount * 1.6))
            } else {
                // 还没抓到画面（刚开始，或超过同时抓取上限）：先用薄雾顶着
                win.alphaValue = Self.maxAlpha * amount
                v.layer?.backgroundColor = veil.cgColor
                v.base.opacity = 0
                v.rim.opacity = 0
            }
            CATransaction.commit()
            return
        }
        win.alphaValue = 1
        if #available(macOS 26, *), let glass = win.contentView as? NSGlassEffectView {
            // 玻璃本身随时间变厚；染色让它在浅色/深色下都不发灰
            glass.alphaValue = min(1, amount * 1.4)
            glass.tintColor = veil.withAlphaComponent(0.34 * amount)
        } else {
            win.contentView?.layer?.backgroundColor = veil.withAlphaComponent(Self.maxAlpha * amount).cgColor
        }
    }

    private func makeOverlay() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.animationBehavior = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        if effectiveStyle == .seeThrough {
            win.contentView = SeeView(frame: .zero)
        } else if #available(macOS 26, *), effectiveStyle == .glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            win.contentView = glass
        } else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.masksToBounds = true
            v.layer?.contentsGravity = .resize
            win.contentView = v
        }
        return win
    }

    private func clearOverlays() {
        MainActor.assumeIsolated { seeThrough.stopAll() }
        overlays.values.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        shown.removeAll()
    }
}
