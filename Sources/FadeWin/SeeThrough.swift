import AppKit
import CoreMedia
import ScreenCaptureKit

/// 一个窗口的“后面”：实时抓取去掉这个窗口之后的屏幕，贴在窗口上方的雾层里。
/// 雾层再按比例变透明，叠起来的效果就是这个窗口本身变透明了
final class Replica: NSObject, SCStreamOutput, SCStreamDelegate {
    let stream: SCStream
    weak var view: SeeView?
    /// 边框画在这三块轮流用的画布上，避免正在显示的那块被下一帧改写
    private var rimPool: [IOSurface] = []
    private var rimIndex = 0
    private(set) var live = false
    var bounds: CGRect
    var excluded: Set<CGWindowID>
    var updating = false
    var onStop: (() -> Void)?

    init(stream: SCStream, view: SeeView, bounds: CGRect, excluded: Set<CGWindowID>) {
        self.stream = stream
        self.view = view
        self.bounds = bounds
        self.excluded = excluded
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surfaceRef = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)

        // 在抓取线程上把边框画好，主线程只负责换图
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if rimPool.first.map({ $0.width != w || $0.height != h }) ?? true {
            rimPool = (0..<3).compactMap { _ in GlassRim.makeSurface(width: w, height: h) }
        }
        var rimSurface: IOSurface?
        if rimPool.count == 3 {
            let dest = rimPool[rimIndex]
            rimIndex = (rimIndex + 1) % 3
            let scale = CGFloat(w) / max(bounds.width, 1)
            if GlassRim.render(surface, scale: scale, into: dest) { rimSurface = dest }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.base.contents = surface
            if let rimSurface { view.rim.contents = rimSurface }
            CATransaction.commit()
            self.live = true
        }
    }

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

    func stopAll() {
        for (_, r) in replicas { Task { try? await r.stream.stopCapture() } }
        replicas.removeAll()
    }

    /// 每次轮询调一次：targets 是正在褪色的窗口和它们的雾层视图，order 是屏幕上所有窗口从前到后的顺序。
    /// 一个窗口的“后面”= 屏幕去掉它自己以及所有在它前面的窗口（含 Dock、菜单栏、前面窗口的雾层）。
    /// 这样后面窗口的雾层里不会混进前面窗口的旧画面，叠在一起的窗口各褪各的
    func sync(targets: [CGWindowID: (win: WinInfo, view: SeeView, overlay: CGWindowID, frozen: Bool)], order: [CGWindowID]) {
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
                // 正在恢复（窗口刚被点回前台）时不换抓取范围：换的那一下画面会跳，看起来就是闪
                guard !r.updating, !t.frozen else { continue }
                if r.bounds != t.win.bounds || r.excluded != wanted {
                    update(r, bounds: t.win.bounds, excluding: wanted, content: content)
                }
            } else if !t.frozen, !starting.contains(id), replicas.count + starting.count < Self.maxReplicas {
                start(id: id, win: t.win, view: t.view, excluding: wanted, content: content)
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
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: replicas.count >= 3 ? 15 : 30)
        return cfg
    }

    private func filter(display: SCDisplay, excluding ids: Set<CGWindowID>, content: SCShareableContent) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: content.windows.filter { ids.contains($0.windowID) })
    }

    private func start(id: CGWindowID, win: WinInfo, view: SeeView, excluding excluded: Set<CGWindowID>, content: SCShareableContent) {
        guard let disp = display(for: win.bounds, in: content) else { return }
        let stream = SCStream(filter: filter(display: disp, excluding: excluded, content: content),
                              configuration: config(bounds: win.bounds, display: disp), delegate: nil)
        let replica = Replica(stream: stream, view: view, bounds: win.bounds, excluded: excluded)
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
            try? await r.stream.updateConfiguration(cfg)
            try? await r.stream.updateContentFilter(flt)
            r.bounds = bounds
            r.excluded = excluded
        }
    }
}
