import AppKit

struct WinInfo {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: CGRect   // CG 坐标：原点在主屏左上角
    var layer: Int = 0   // 0 普通窗口；3 浮动面板（很多 App 的设置窗口）；8 模态面板
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
        set {
            UserDefaults.standard.set(newValue, forKey: "paused")
            if newValue {
                clearOverlays()
                MainActor.assumeIsolated { motion.stopAll() }
                movingWindows = []
            } else {
                lastFocus.removeAll()   // 暂停期间不算闲置
            }
        }
    }

    var speed: FadeSpeed {
        get { FadeSpeed(rawValue: UserDefaults.standard.string(forKey: "speed") ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speed") }
    }

    /// 透视时给窗口自己的内容加一层磨砂，别人看不清上面的字（默认开）
    var privacyFrost: Bool {
        get { !UserDefaults.standard.bool(forKey: "noPrivacyFrost") }
        set { UserDefaults.standard.set(!newValue, forKey: "noPrivacyFrost") }
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
        if style == .seeThrough, !permissionCached { return FadeStyle.glassAvailable ? .glass : .veil }
        return style
    }

    /// 屏幕录制权限每 3 秒查一次就够了，不必每次轮询都问系统
    private var permissionChecked = Date.distantPast
    private var permissionValue = false
    private var permissionCached: Bool {
        if Date().timeIntervalSince(permissionChecked) > 3 {
            permissionValue = SeeThrough.hasPermission
            permissionChecked = Date()
        }
        return permissionValue
    }

    private var overlayStyle: FadeStyle?
    private lazy var seeThrough: SeeThrough = MainActor.assumeIsolated { SeeThrough() }

    /// 每个窗口“应该”褪到多少（0...1，按闲置时间算），和“现在画出来”是多少；动画让后者平滑追上前者
    private var targets: [CGWindowID: CGFloat] = [:]
    private var shown: [CGWindowID: CGFloat] = [:]
    private var animTimer: Timer?
    private let frameTicker = FrameTicker()
    private var displayLink: AnyObject?
    private var lastAnim = Date()

    /// 窗口在动（拖动、显示桌面时一起滑开）时雾层先藏起来，停稳了再淡回来；vis 就是这个“显现度”
    private var lastMoved: [CGWindowID: Date] = [:]
    private var vis: [CGWindowID: CGFloat] = [:]
    private var settled: [CGWindowID: Bool] = [:]
    private var captureBounds: [CGWindowID: CGRect] = [:]
    private var inMissionControl = false
    /// 屏幕上所有窗口（任何层级）从前到后的位置，用来判断鼠标真正点中的是谁
    private var allFrames: [(id: CGWindowID, bounds: CGRect, opaque: Bool)] = []
    private var pollCount = 0
    static let settleDelay: TimeInterval = 0.35

    /// 透视时窗口最多透明到这里，保留一点影子，免得彻底看不见
    static let maxSeeThrough: CGFloat = 0.72

    func start() {
        // 每秒 20 次检查（大多只取窗口编号，很便宜），好尽早发现窗口在动；没有雾层时 poll 里再降到 4 次/秒
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 动画跟着屏幕刷新走（120 Hz 屏上就是 120 帧）；macOS 13 没有这个接口，退回 60 Hz 计时器
        if #available(macOS 14, *) {
            frameTicker.onTick = { [weak self] in self?.animate() }
            makeDisplayLink()
            // 刷新回调绑在某块屏幕上：接上/拔掉显示器后那块屏幕可能没了，回调就停了，要重建
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in self?.makeDisplayLink() }
        } else {
            let a = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.animate() }
            RunLoop.main.add(a, forMode: .common)
            animTimer = a
        }

        // 点下去的那一刻就把雾层提到最上面，赶在窗口被系统提到前台之前；
        // 否则窗口会先盖住雾层（一下变清晰），下一次轮询雾层又盖回来（一下变模糊），就是闪
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.mouseDown() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            // 切到访达以外的 App，“停在桌面上”的状态就结束了
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier != Self.finder { self?.onDesktop = false }
            self?.poll()
        }
    }

    @available(macOS 14, *)
    private func makeDisplayLink() {
        (displayLink as? CADisplayLink)?.invalidate()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { displayLink = nil; return }
        let link = screen.displayLink(target: frameTicker, selector: #selector(FrameTicker.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastAnim = Date()
    }

    static let finder = "com.apple.finder"
    /// 最近一次点击落在桌面上、并且之后还没点过任何窗口。
    /// 这时前台虽然是访达，但用户在用的是桌面，访达的窗口不该算“正在用”
    private var onDesktop = false

    private func mouseDown() {
        boostUntil = Date().addingTimeInterval(1.5)
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        let pt = CGPoint(x: p.x, y: h - p.y)
        // 点在 Dock 或菜单栏那一条里就不算（屏幕“可用区域”之外）
        guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(p) }) else { return }
        // 按真实层级找最上面那个被点中的普通窗口或面板（跳过我们自己的雾层）。
        // 不能用所有窗口：Dock 是一张盖满全屏的透明窗口，排在最前面，会把所有点击都“接走”
        let mine = Set(overlays.values.map { CGWindowID($0.windowNumber) })
        let hitAny = allFrames.first(where: { $0.opaque && !mine.contains($0.id) && $0.bounds.contains(pt) })
        // 没点中任何窗口 = 点在桌面上（系统会把访达切到前台，但用户并没有在用访达的窗口）
        onDesktop = hitAny == nil
        guard let hit = hitAny,
              let w = snapshot.first(where: { $0.id == hit.id }),
              let win = overlays[w.id], (shown[w.id] ?? 0) > 0.002 else { return }
        lastFocus[w.id] = Date()
        targets[w.id] = 0
        raise(win, above: w.layer)
    }

    /// 正在恢复的雾层放到目标窗口所在层级之上：它盖着的窗口这时本来就在最前面，所以看起来没区别，但不会被窗口抢到上面
    private func raise(_ win: NSWindow, above layer: Int) {
        let up = NSWindow.Level(rawValue: layer + 1)
        guard win.level != up else { return }
        win.level = up
        win.orderFront(nil)
    }

    // MARK: - 锁定、例外、全部恢复

    /// 本次运行里锁定的窗口。窗口编号重启后会变，所以不存盘
    private(set) var lockedWindows: Set<CGWindowID> = []

    /// 永不褪色的 App，按 Bundle ID 存盘
    /// 每次轮询每个窗口都要查，所以缓存在内存里，只在改动时写盘
    lazy var exemptApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "exemptApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(exemptApps).sorted(), forKey: "exemptApps") }
    }

    private var bundleIDs: [pid_t: String] = [:]

    /// 正在播放视频的 App（每秒查一次）；它们的窗口不褪色，免得看视频时画面被盖住
    private(set) var videoPids: Set<pid_t> = []
    /// 画面在持续变化的窗口（静音视频、播放器里的画面），同样不褪色
    private(set) var movingWindows: Set<CGWindowID> = []
    private lazy var motion: MotionWatch = MainActor.assumeIsolated { MotionWatch() }
    private var videoChecked = Date.distantPast
    private var lastMotion: [CGWindowID: Date] = [:]

    func bundleID(of pid: pid_t) -> String? {
        if let b = bundleIDs[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if let b { bundleIDs[pid] = b }
        return b
    }

    /// 用户正在用的窗口。点菜单栏图标不会切换前台 App，所以打开菜单时这就是用户刚才在用的那个
    var frontWindow: WinInfo? {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 和“正在用”同一个标准：排在最前面的普通窗口属于前台 App 才算；
        // 点过桌面时前台是访达，但它的窗口可能压在后面，不能拿来锁
        if onDesktop, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder { return nil }
        if let w = snapshot.first(where: { $0.layer == 0 }), w.pid == pid { return w }
        return snapshot.first { $0.layer != 0 && $0.pid == pid }
    }

    func isLocked(_ id: CGWindowID) -> Bool { lockedWindows.contains(id) }

    func toggleLock(_ id: CGWindowID) {
        if lockedWindows.remove(id) == nil { lockedWindows.insert(id) }
        lastFocus[id] = Date()   // 解锁后从清晰开始重新计时
    }

    /// 锁定/解锁当前窗口，返回操作后是否处于锁定状态；没有可操作的窗口时返回 nil
    @discardableResult
    func toggleLockFrontWindow() -> Bool? {
        guard let w = frontWindow else { return nil }
        toggleLock(w.id)
        return isLocked(w.id)
    }

    /// 所有窗口立刻恢复清晰，并从现在重新计时
    func restoreAll() {
        let now = Date()
        for id in lastFocus.keys { lastFocus[id] = now }
    }

    /// 锁定的窗口、例外 App 的窗口、正在放视频的 App 的窗口都不褪色
    private func isExempt(_ w: WinInfo) -> Bool {
        if lockedWindows.contains(w.id) { return true }
        if videoPids.contains(w.pid) || movingWindows.contains(w.id) { return true }
        if let b = bundleID(of: w.pid), exemptApps.contains(b) { return true }
        return false
    }

    func idleSeconds(of id: CGWindowID) -> Double {
        lastFocus[id].map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: - 窗口列表

    /// 处理哪些层级的窗口：普通窗口，加上浮动面板和模态面板（有些 App 的设置窗口就是浮动面板）。
    /// 输入法候选框、Dock、菜单栏都在更高的层级，不会被算进来
    static let fadeLayers: Set<Int> = [0, 3, 8]

    /// 返回要处理的普通窗口、屏幕上所有窗口（含 Dock、菜单栏、我们自己的雾层）从前到后的顺序，
    /// 以及调度中心（三指上滑）是否正开着
    static func onScreenWindows() -> (wins: [WinInfo], order: [CGWindowID], frames: [(id: CGWindowID, bounds: CGRect, opaque: Bool)], missionControl: Bool) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return ([], [], [], false) }
        var out: [WinInfo] = []
        var order: [CGWindowID] = []
        var frames: [(id: CGWindowID, bounds: CGRect, opaque: Bool)] = []
        var mc = false
        for w in list {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            order.append(id)
            if let bd = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: bd as CFDictionary),
               (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 {
                // 能“挡住”别的窗口的只有普通窗口和面板，而且得基本不透明。
                // Dock 在系统里是一张盖满全屏的透明窗口，菜单栏、各种系统层也一样，它们都不算
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                let opaque = Self.fadeLayers.contains(layer) && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.95
                frames.append((id, b, opaque))
            }
            // 调度中心开着时系统会铺一层 ExposeShieldWindow；没有屏幕录制权限读不到窗口名，就按所属进程和层级认
            let name = w[kCGWindowName as String] as? String
            if name == "ExposeShieldWindow" ||
                (name == nil && (w[kCGWindowOwnerName as String] as? String) == "WindowManager" && (w[kCGWindowLayer as String] as? Int) == 19) {
                mc = true
            }
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard Self.fadeLayers.contains(layer),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  b.width >= 120, b.height >= 80 else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" { continue }
            out.append(WinInfo(id: id, pid: pid, owner: owner, title: w[kCGWindowName as String] as? String ?? "", bounds: b, layer: layer))
        }
        return (out, order, frames, mc)
    }

    private typealias ListCreate = @convention(c) (CGWindowListOption, CGWindowID) -> Unmanaged<CFArray>?
    /// 只取窗口编号的查询，比完整查询便宜得多。Swift 里被标成不可用，通过函数指针调用；
    /// 返回的数组里直接装着编号数值（不是 NSNumber）
    private static let listCreate: ListCreate? = dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
                                                       "CGWindowListCreate").map { unsafeBitCast($0, to: ListCreate.self) }

    static func windowIDs() -> [CGWindowID]? {
        guard let f = listCreate, let arr = f([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)?.takeRetainedValue() else { return nil }
        return (0..<CFArrayGetCount(arr)).map { CGWindowID(UInt(bitPattern: CFArrayGetValueAtIndex(arr, $0))) }
    }

    // MARK: - 每 0.05 秒：算目标、跟随窗口位置

    private var lastPoll = Date.distantPast
    /// 上一次完整查询的结果；窗口编号和顺序没变、又不到下一次完整查询时就直接复用
    private var cachedList: (wins: [WinInfo], order: [CGWindowID], frames: [(id: CGWindowID, bounds: CGRect, opaque: Bool)], missionControl: Bool)?
    private var lastFull = Date.distantPast
    /// 鼠标按下后的一小段时间里窗口很可能在动（拖动、点桌面让窗口散开），这段时间每次都完整查询
    private var boostUntil = Date.distantPast

    private func poll() {
        guard !paused else { return }
        // 有雾层在屏幕上时每秒 20 次（要及时发现窗口在动）；没有时每秒 4 次就够算闲置了
        let started = Date()
        if overlays.isEmpty, started.timeIntervalSince(lastPoll) < 0.25 { return }
        lastPoll = started
        // 先只取编号：窗口有增减、换了顺序（含调度中心出现）都会反映在这里，便宜又及时；
        // 编号没变时，完整查询（为了跟上窗口位置）平时每秒 10 次，鼠标按下后的 1.5 秒内每次都查
        let ids = Self.windowIDs()
        let fullInterval: TimeInterval = started < boostUntil ? 0 : 0.1
        let list: (wins: [WinInfo], order: [CGWindowID], frames: [(id: CGWindowID, bounds: CGRect, opaque: Bool)], missionControl: Bool)
        if let cached = cachedList, let ids, ids == cached.order, started.timeIntervalSince(lastFull) < fullInterval {
            list = cached
        } else {
            list = Self.onScreenWindows()
            cachedList = list
            lastFull = started
        }
        let (wins, order, frames, missionControl) = list
        let now = Date()

        // 调度中心开着时窗口被系统缩放成缩略图，位置数据却不变，雾层没法跟：全部藏起来，什么都不动。
        // 退出后窗口还要飞回原位，多等一会儿，并且等抓取画面换成新的再淡回来
        if missionControl {
            if !inMissionControl {
                inMissionControl = true
                for (id, win) in overlays { vis[id] = 0; win.alphaValue = 0; applied[id] = nil }
            }
            return
        }
        if inMissionControl {
            inMissionControl = false
            for id in overlays.keys { lastMoved[id] = now.addingTimeInterval(0.35) }
            MainActor.assumeIsolated { seeThrough.awaitFreshFrames() }
        }
        snapshot = wins
        allFrames = frames
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 只有真正排在最前面、又属于前台 App 的窗口才算“正在用”。
        // 点桌面时访达会变成前台 App，但它的窗口可能压在别的窗口后面，不能算。
        // 普通窗口和面板分开看：别的 App 的常驻浮窗挡在最前面，不影响普通窗口里谁是“正在用”；
        // 前台 App 自己的面板（比如设置窗口）在最前面时，它也算正在用
        // 点过桌面、前台变成访达时：访达最上面那个窗口并没有在用，不算
        let desktopOnly = onDesktop && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder
        let focusedID: CGWindowID? = desktopOnly ? nil : wins.first(where: { $0.layer == 0 }).flatMap { $0.pid == frontPid ? $0.id : nil }
        let focusedPanel: CGWindowID? = desktopOnly ? nil : wins.first(where: { $0.layer != 0 }).flatMap { $0.pid == frontPid ? $0.id : nil }
        if let focusedID { lastFocus[focusedID] = now }
        if let focusedPanel { lastFocus[focusedPanel] = now }
        let alive = Set(wins.map(\.id))
        if now.timeIntervalSince(videoChecked) > 1 {
            videoPids = VideoWatch.playingPids()
            videoChecked = now
        }
        // 盯着快要褪色的窗口看画面在不在动（前面的优先）。只在透视外观下做：
        // 这要用屏幕抓取，系统会亮起录屏指示；用户选玻璃或薄雾就是不想抓屏，那时只靠“防休眠申请”识别视频。
        // 被认定在动的窗口闲置时间会一直被清零，所以“最近 10 秒在动过”的也要接着盯，不然会探头一关它就褪、一褪又被探到，来回折腾
        if permissionCached, effectiveStyle == .seeThrough {
            let grace = speed.span.grace
            let overlayIDs = Set(overlays.values.map { CGWindowID($0.windowNumber) })
            let watch = wins.filter { w in
                guard w.id != focusedID, !lockedWindows.contains(w.id), !videoPids.contains(w.pid) else { return false }
                let idle = now.timeIntervalSince(lastFocus[w.id] ?? now)
                let recentlyMoving = now.timeIntervalSince(lastMotion[w.id] ?? .distantPast) < 10
                guard idle >= grace * 0.5 || recentlyMoving else { return false }
                return !Self.isFullyCovered(w.bounds, by: frames, before: w.id, ignoring: overlayIDs)
            }.map(\.id)
            movingWindows = MainActor.assumeIsolated {
                motion.sync(candidates: watch)
                return Set(watch.filter { motion.isMoving($0) })
            }
            for id in movingWindows { lastMotion[id] = now }
        } else {
            // 从透视切走时把探头全停掉，录屏指示才会消失
            if !movingWindows.isEmpty || !lastMotion.isEmpty { lastMotion.removeAll() }
            movingWindows = []
            MainActor.assumeIsolated { motion.stopAll() }
        }
        for w in wins where lastFocus[w.id] == nil || isExempt(w) { lastFocus[w.id] = now }
        // 不在屏幕上的窗口（切到别的桌面空间、最小化）保留计时，回来时接着褪；每 10 秒清一次已经关掉的
        pollCount += 1
        if pollCount % 300 == 0, let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            let exists = Set(all.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
            lastFocus = lastFocus.filter { exists.contains($0.key) }
            lockedWindows.formIntersection(exists)
            bundleIDs.removeAll()
        }
        for (id, win) in overlays where !alive.contains(id) {
            win.orderOut(nil)
            overlays[id] = nil
            applied[id] = nil
        }
        targets = targets.filter { alive.contains($0.key) }
        shown = shown.filter { alive.contains($0.key) }
        lastMoved = lastMoved.filter { alive.contains($0.key) }
        lastMotion = lastMotion.filter { alive.contains($0.key) }
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
        var seeTargets: [CGWindowID: (win: WinInfo, view: SeeView, overlay: CGWindowID, frozen: Bool, edges: Edges, covered: Bool)] = [:]
        let mine = Set(overlays.values.map { CGWindowID($0.windowNumber) })
        var coveredWindows = Set<CGWindowID>()

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
                applied[w.id] = nil
            }
            if win.frame != frame {
                if win.frame.width > 0 {
                    // 窗口动了：雾层立刻藏起来，别追着窗口跑
                    lastMoved[w.id] = now
                    vis[w.id] = 0
                    win.alphaValue = 0
                    applied[w.id] = nil
                }
                win.setFrame(frame, display: false)
            }
            let moving = now.timeIntervalSince(lastMoved[w.id] ?? .distantPast) < Self.settleDelay
            settled[w.id] = !moving
            captureBounds[w.id] = b
            let level = NSWindow.Level(rawValue: w.layer)
            if w.id == focusedID || w.id == focusedPanel, target <= 0.002 {
                raise(win, above: w.layer)
            } else {
                if win.level != level { win.level = level }
                // 只在雾层不在窗口正上方时才调整层级，少折腾窗口服务器
                let oi = order.firstIndex(of: CGWindowID(win.windowNumber)), wi = order.firstIndex(of: w.id)
                if oi == nil || wi == nil || oi! + 1 != wi! { win.order(.above, relativeTo: Int(w.id)) }
            }
            let hidden = Self.isFullyCovered(b, by: frames, before: w.id, ignoring: mine)
            if hidden { coveredWindows.insert(w.id) }
            if current == .seeThrough, let v = win.contentView as? SeeView {
                // 被屏幕边缘截掉的边不是真边：那里不画圆角也不画玻璃边框（CG 坐标里 minY 是上边）
                var edges: Edges = []
                if b.minX <= w.bounds.minX + 0.5 { edges.insert(.left) }
                if b.maxX >= w.bounds.maxX - 0.5 { edges.insert(.right) }
                if b.minY <= w.bounds.minY + 0.5 { edges.insert(.top) }
                if b.maxY >= w.bounds.maxY - 0.5 { edges.insert(.bottom) }
                v.edges = edges
                let clipped = WinInfo(id: w.id, pid: w.pid, owner: w.owner, title: w.title, bounds: b, layer: w.layer)
                seeTargets[w.id] = (clipped, v, CGWindowID(win.windowNumber), target <= 0.002 || moving, edges, hidden)
            }
        }

        if current == .seeThrough {
            MainActor.assumeIsolated { seeThrough.sync(targets: seeTargets, order: order) }
        }

        // 动画暂停时只有这里能把它叫醒：有窗口还没褪到位/没恢复完、透视画面就绪了、外观设置变了
        let live = current == .seeThrough ? MainActor.assumeIsolated { Set(overlays.keys.filter { seeThrough.isLive($0) }) } : []
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let pending = overlays.keys.contains { abs((targets[$0] ?? 0) - (shown[$0] ?? 0)) > 0.001 || (vis[$0] ?? 1) < 1 }
        if pending || live != lastLive || dark != lastDark || privacyFrost != lastPrivacy {
            setAnimationPaused(false)
        }
        lastLive = live
        lastDark = dark
        lastPrivacy = privacyFrost
    }

    /// 窗口是不是被它前面的窗口完全挡住了（在窗口上撒一张 8×6 的点阵，每个点都被挡住才算）。
    /// 完全看不见的窗口不必抓画面、也不必看它在不在动
    static func isFullyCovered(_ b: CGRect, by frames: [(id: CGWindowID, bounds: CGRect, opaque: Bool)], before id: CGWindowID, ignoring mine: Set<CGWindowID>) -> Bool {
        guard let idx = frames.firstIndex(where: { $0.id == id }), idx > 0 else { return false }
        let front = frames[..<idx].filter { $0.opaque && !mine.contains($0.id) }.map(\.bounds)
        guard !front.isEmpty else { return false }
        let r = b.insetBy(dx: 4, dy: 4)
        for i in 0..<8 {
            for j in 0..<6 {
                let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / 7, y: r.minY + r.height * CGFloat(j) / 5)
                if !front.contains(where: { $0.contains(pt) }) { return false }
            }
        }
        return true
    }

    // MARK: - 每帧：平滑过渡

    /// 连续多少帧什么都没变；够多了就暂停屏幕刷新回调，省掉每秒上百次的唤醒
    private var quietFrames = 0
    private var lastLive = Set<CGWindowID>()
    private var lastDark = false
    private var lastPrivacy = true

    private func setAnimationPaused(_ paused: Bool) {
        if #available(macOS 14, *), let link = displayLink as? CADisplayLink, link.isPaused != paused {
            link.isPaused = paused
            if !paused { lastAnim = Date() }
        }
    }

    private func animate() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastAnim), 0.1)
        lastAnim = now
        guard !overlays.isEmpty else {
            setAnimationPaused(true)
            return
        }
        var changed = false
        defer {
            quietFrames = changed ? 0 : quietFrames + 1
            if quietFrames > 30 { setAnimationPaused(true) }
        }

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
            applied[id] = nil
                shown[id] = 0
                continue
            }

            // 停稳之后再淡回来；透视还要等抓取画面对上新位置，不然会先闪一下旧画面
            var ready = !inMissionControl && (settled[id] ?? true)
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
            if s != target || v < 1 { changed = true }
            vis[id] = v
            if apply(amount: s * v, id: id, style: current, veil: veil, to: win) { changed = true }
        }
    }

    /// 上一次画到每个雾层上的状态；没变就不再设，每次设置都要和窗口服务器通信，每秒上百次很费电
    private struct Applied: Equatable { var amount: CGFloat; var live: Bool; var dark: Bool; var frost: Bool }
    private var applied: [CGWindowID: Applied] = [:]

    /// amount: 0...1，0 是没褪，1 是褪到最浅。返回这次有没有真的改动
    @discardableResult
    private func apply(amount: CGFloat, id: CGWindowID, style: FadeStyle, veil: NSColor, to win: NSWindow) -> Bool {
        let live = style == .seeThrough && MainActor.assumeIsolated({ seeThrough.isLive(id) })
        let state = Applied(amount: (amount * 1000).rounded() / 1000, live: live, dark: veil.whiteComponent < 0.5, frost: privacyFrost)
        if applied[id] == state { return false }
        applied[id] = state

        if style == .seeThrough, let v = win.contentView as? SeeView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if live {
                // 中间：盖上“窗口后面”的实时画面，按比例变淡，看起来就是窗口本身变透明了
                // 边缘：玻璃边框比中间更早、更实地出现，褪尽之后窗口轮廓依然清楚
                win.alphaValue = 1
                v.layer?.backgroundColor = nil
                v.frost.alphaValue = privacyFrost ? min(1, amount * 1.3) : 0
                v.base.opacity = Float(Self.maxSeeThrough * amount)
                v.rim.opacity = Float(min(1, amount * 1.6))
            } else {
                // 还没抓到画面（刚开始，或没分到抓取名额）：用磨砂玻璃顶着，样子接近透视，不会是一片白
                win.alphaValue = 1
                v.layer?.backgroundColor = veil.withAlphaComponent(0.3 * amount).cgColor
                v.frost.alphaValue = min(1, amount * 1.3)
                v.base.opacity = 0
                v.rim.opacity = 0
            }
            CATransaction.commit()
            return true
        }
        win.alphaValue = 1
        if #available(macOS 26, *), let glass = win.contentView as? NSGlassEffectView {
            // 玻璃本身随时间变厚；染色让它在浅色/深色下都不发灰
            glass.alphaValue = min(1, amount * 1.4)
            glass.tintColor = veil.withAlphaComponent(0.34 * amount)
        } else {
            win.contentView?.layer?.backgroundColor = veil.withAlphaComponent(Self.maxAlpha * amount).cgColor
        }
        return true
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
        applied.removeAll()
        shown.removeAll()
    }
}

/// 屏幕刷新回调需要一个 Objective-C 对象当目标，Fader 不是，所以转一手
final class FrameTicker: NSObject {
    var onTick: (() -> Void)?
    @objc func tick() { onTick?() }
}
