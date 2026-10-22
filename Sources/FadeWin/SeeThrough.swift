import AppKit
import CoreMedia
import ScreenCaptureKit
import os

/// 一个窗口的“后面”：实时抓取去掉这个窗口之后的屏幕，贴在窗口上方的雾层里。
/// 雾层再按比例变透明，叠起来的效果就是这个窗口本身变透明了
final class Replica: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var stream: SCStream!
    weak var view: SeeView?
    /// 当前抓取设定的像素尺寸；尺寸对不上的帧是改范围之前的旧帧，不算“有新画面”
    private var expectedSize: (w: Int, h: Int)
    /// 边框画在这三块轮流用的画布上，避免正在显示的那块被下一帧改写
    private var rimPool: [IOSurface] = []
    private var rimIndex = 0
    /// 画布上画的是哪几条边；变了就得换新画布，不然被截掉那一侧会留下旧边框
    private var poolEdges: Edges = .all
    /// 边框每秒最多重画 10 次：边框里只是被折射的背景，晚一点看不出来，但每次重画都很费 CPU
    private var lastRim: CFTimeInterval = 0
    private static let rimInterval: CFTimeInterval = 0.1
    private(set) var live = false
    // 抓取线程只需要这两个值；一起取快照，避免画边框时和主线程争读写
    private struct CaptureGeometry {
        var width: CGFloat
        var edges: Edges = .all
    }
    private let geometry: OSAllocatedUnfairLock<CaptureGeometry>
    var bounds: CGRect {
        didSet { geometry.withLock { $0.width = bounds.width } }
    }
    var excluded: Set<CGWindowID>
    var edges: Edges {
        get { geometry.withLock { $0.edges } }
        set { geometry.withLock { $0.edges = newValue } }
    }
    var updating = false
    var onStop: (() -> Void)?

    init(filter: SCContentFilter, config: SCStreamConfiguration, view: SeeView, bounds: CGRect, excluded: Set<CGWindowID>) {
        self.view = view
        self.bounds = bounds
        geometry = OSAllocatedUnfairLock(initialState: CaptureGeometry(width: bounds.width))
        self.excluded = excluded
        expectedSize = (config.width, config.height)
        super.init()
        // 自己当委托：抓取意外停止（息屏、拔显示器等）时能收到通知，下一轮重新抓
        stream = SCStream(filter: filter, configuration: config, delegate: self)
    }

    /// 在主线程调用：抓取范围改了
    func expect(_ config: SCStreamConfiguration) { expectedSize = (config.width, config.height) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surfaceRef = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)

        // 在抓取线程上把边框画好，主线程只负责换图
        let geometry = geometry.withLock { $0 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let now = CACurrentMediaTime()
        let edgesChanged = poolEdges != geometry.edges
        if rimPool.first.map({ $0.width != w || $0.height != h }) ?? true || edgesChanged {
            rimPool = (0..<3).compactMap { _ in GlassRim.makeClearSurface(width: w, height: h) }
            poolEdges = geometry.edges
        }
        var rimSurface: IOSurface?
        if rimPool.count == 3, now - lastRim >= Self.rimInterval || edgesChanged {
            lastRim = now
            let dest = rimPool[rimIndex]
            rimIndex = (rimIndex + 1) % 3
            let scale = CGFloat(w) / max(geometry.width, 1)
            if GlassRim.render(surface, scale: scale, edges: geometry.edges, into: dest) { rimSurface = dest }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view else { return }
            let fresh = w == self.expectedSize.w && h == self.expectedSize.h
            if !fresh && !self.live { return }   // 还在等新范围的帧，旧帧不要
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.base.contents = surface
            if let rimSurface { view.rim.contents = rimSurface }
            CATransaction.commit()
            if fresh { self.live = true }
        }
    }

    /// 改完抓取范围后，等新范围的第一帧到了才重新算“有画面”
    func awaitFreshFrame() { live = false }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.live = false
            self?.onStop?()
        }
    }
}

@MainActor final class SeeThrough {
    static let maxReplicas = 6

    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    private var refreshing = false
    private var replicas: [CGWindowID: Replica] = [:]
    private var starting: Set<CGWindowID> = []
    private let queue = DispatchQueue(label: "local.tenko.fadewin.capture")

    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func isLive(_ id: CGWindowID) -> Bool { replicas[id]?.live ?? false }

    func awaitFreshFrames() { replicas.values.forEach { $0.awaitFreshFrame() } }

    /// 抓取范围已经对上这个位置、并且有画面了。还没抓起来的（比如超过同时抓取上限）也算好了，交给薄雾顶着
    func isReady(_ id: CGWindowID, bounds: CGRect) -> Bool {
        guard let r = replicas[id] else { return !starting.contains(id) }
        return r.live && r.bounds == bounds
    }

    func stopAll() {
        for (_, r) in replicas { Task { try? await r.stream.stopCapture() } }
        replicas.removeAll()
    }

    /// 每次轮询调一次：targets 是正在褪色的窗口和它们的雾层视图，order 是屏幕上所有窗口从前到后的顺序。
    /// 一个窗口的“后面”= 屏幕去掉它自己以及所有在它前面的窗口（含 Dock、菜单栏、前面窗口的雾层）。
    /// 这样后面窗口的雾层里不会混进前面窗口的旧画面，叠在一起的窗口各褪各的
    func sync(targets: [CGWindowID: (win: WinInfo, view: SeeView, overlay: CGWindowID, frozen: Bool, edges: Edges)], order: [CGWindowID]) {
        for id in replicas.keys where targets[id] == nil {
            if let r = replicas.removeValue(forKey: id) { Task { try? await r.stream.stopCapture() } }
        }
        guard !targets.isEmpty else { return }

        var front: [CGWindowID: Set<CGWindowID>] = [:]
        for (id, t) in targets {
            guard let idx = order.firstIndex(of: id) else { continue }
            // 刚建的雾层可能还没出现在 order 里，直接把它也排除，免得抓到自己
            front[id] = Set(order[...idx]).union([t.overlay])
        }
        let needed = front.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) }
        let known = Set((content?.windows ?? []).map(\.windowID))
        if !needed.isSubset(of: known) || Date().timeIntervalSince(contentDate) > 5 { refresh() }
        guard let content else { return }

        for (id, t) in targets {
            guard let wanted = front[id]?.intersection(known) else { continue }
            if let r = replicas[id] {
                r.edges = t.edges
                // 正在恢复（窗口刚被点回前台）时不换抓取范围：换的那一下画面会跳，看起来就是闪
                guard !r.updating, !t.frozen else { continue }
                if r.bounds != t.win.bounds || r.excluded != wanted {
                    update(r, bounds: t.win.bounds, excluding: wanted, content: content)
                }
            } else if !t.frozen, !starting.contains(id), replicas.count + starting.count < Self.maxReplicas {
                start(id: id, win: t.win, view: t.view, excluding: wanted, edges: t.edges, content: content)
            }
        }
    }

    private func refresh() {
        guard !refreshing, Date().timeIntervalSince(contentDate) > 0.4 else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false; contentDate = Date() }
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    // MARK: - 流

    private func display(for bounds: CGRect, in content: SCShareableContent) -> SCDisplay? {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return content.displays.first { $0.frame.contains(c) } ?? content.displays.first
    }

    private func scale(of display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?
            .backingScaleFactor ?? 2
    }

    private func config(bounds: CGRect, display: SCDisplay) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        // 透出来的画面本来就是半透明的，不必满分辨率：每路最多约 220 万像素，同时开多路也不卡
        let s = min(scale(of: display), sqrt(2_200_000 / max(bounds.width * bounds.height, 1)))
        cfg.sourceRect = CGRect(x: bounds.minX - display.frame.minX, y: bounds.minY - display.frame.minY,
                                width: bounds.width, height: bounds.height)
        cfg.width = max(Int(bounds.width * s), 2)
        cfg.height = max(Int(bounds.height * s), 2)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.queueDepth = 3
        // 透出来的是半透明的背景，20 帧足够顺；同时透视的窗口多了再减半，省电
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: replicas.count >= 3 ? 10 : 20)
        return cfg
    }

    private func filter(display: SCDisplay, excluding ids: Set<CGWindowID>, content: SCShareableContent) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: content.windows.filter { ids.contains($0.windowID) })
    }

    private func start(id: CGWindowID, win: WinInfo, view: SeeView, excluding excluded: Set<CGWindowID>, edges: Edges, content: SCShareableContent) {
        guard let disp = display(for: win.bounds, in: content) else { return }
        let replica = Replica(filter: filter(display: disp, excluding: excluded, content: content),
                              config: config(bounds: win.bounds, display: disp), view: view, bounds: win.bounds, excluded: excluded)
        replica.edges = edges
        let stream = replica.stream!
        replica.onStop = { [weak self] in
            Task { @MainActor in self?.replicas[id] = nil }
        }
        starting.insert(id)
        Task { @MainActor in
            defer { starting.remove(id) }
            do {
                try stream.addStreamOutput(replica, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                replicas[id] = replica
            } catch {
                NSLog("FadeWin: 抓取失败 \(error.localizedDescription)")
            }
        }
    }

    private func update(_ r: Replica, bounds: CGRect, excluding excluded: Set<CGWindowID>, content: SCShareableContent) {
        guard let disp = display(for: bounds, in: content) else { return }
        r.updating = true
        let cfg = config(bounds: bounds, display: disp)
        let flt = filter(display: disp, excluding: excluded, content: content)
        Task { @MainActor in
            defer { r.updating = false }
            let moved = r.bounds != bounds
            if moved {
                r.expect(cfg)
                try? await r.stream.updateConfiguration(cfg)
            }
            try? await r.stream.updateContentFilter(flt)
            r.bounds = bounds
            r.excluded = excluded
            // 只有位置/尺寸变了才要等新画面；只是层级变了（点了别的窗口）就接着用，免得闪
            if moved { r.awaitFreshFrame() }
        }
    }
}
