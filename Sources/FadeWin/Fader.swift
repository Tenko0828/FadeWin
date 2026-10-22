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
    case glass, veil

    var title: String {
        switch self {
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

    var style: FadeStyle {
        get {
            let saved = FadeStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .glass
            return saved == .glass && !FadeStyle.glassAvailable ? .veil : saved
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style"); clearOverlays() }
    }

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func idleSeconds(of id: CGWindowID) -> Double {
        lastFocus[id].map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: - 窗口列表

    static func onScreenWindows() -> [WinInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WinInfo] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  b.width >= 120, b.height >= 80 else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" { continue }
            out.append(WinInfo(id: id, pid: pid, owner: owner, title: w[kCGWindowName as String] as? String ?? "", bounds: b))
        }
        return out   // 从前到后
    }

    // MARK: - 每半秒一次

    private func tick() {
        guard !paused else { return }
        let wins = Self.onScreenWindows()
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

        let (grace, full) = speed.span
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let veil = dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.94, alpha: 1)
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        for w in wins {
            let idle = now.timeIntervalSince(lastFocus[w.id] ?? now)
            let t = min(max((idle - grace) / (full - grace), 0), 1)
            let alpha = Self.maxAlpha * CGFloat(1 - (1 - t) * (1 - t))   // 先快后慢：刚开始褪就能看出来
            guard alpha > 0.01 else {
                if let o = overlays[w.id] { o.orderOut(nil); overlays[w.id] = nil }
                continue
            }
            let frame = NSRect(x: w.bounds.minX, y: screenH - w.bounds.maxY, width: w.bounds.width, height: w.bounds.height)
            let win = overlays[w.id] ?? makeOverlay()
            overlays[w.id] = win
            win.setFrame(frame, display: false)
            apply(amount: alpha / Self.maxAlpha, veil: veil, to: win)
            win.order(.above, relativeTo: Int(w.id))
        }
    }

    /// amount: 0...1，0 是刚开始褪，1 是褪到最浅
    private func apply(amount: CGFloat, veil: NSColor, to win: NSWindow) {
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
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        if #available(macOS 26, *), style == .glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            win.contentView = glass
        } else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            win.contentView = v
        }
        return win
    }

    private func clearOverlays() {
        overlays.values.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }
}
