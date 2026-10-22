import AppKit
import CoreMedia
import ScreenCaptureKit

/// 一个窗口的“后面”：实时抓取去掉这个窗口之后的屏幕，贴在窗口上方的雾层里。
/// 雾层再按比例变透明，叠起来的效果就是这个窗口本身变透明了
final class Replica: NSObject, SCStreamOutput, SCStreamDelegate {
    let stream: SCStream
    weak var view: NSView?
    private(set) var live = false
    var bounds: CGRect
    var excluded: Set<CGWindowID>
    var updating = false
    var onStop: (() -> Void)?

    init(stream: SCStream, view: NSView, bounds: CGRect, excluded: Set<CGWindowID>) {
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
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.view?.layer else { return }
            layer.contents = surface
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

    /// 每个 tick 调一次：targets 是正在褪色的窗口和它们的雾层视图，overlayIDs 是所有雾层窗口（抓取时要排除）
    func sync(targets: [CGWindowID: (win: WinInfo, view: NSView)], overlayIDs: Set<CGWindowID>) {
        for id in replicas.keys where targets[id] == nil {
            if let r = replicas.removeValue(forKey: id) { Task { try? await r.stream.stopCapture() } }
        }
        guard !targets.isEmpty else { return }

        let needed = Set(targets.keys).union(overlayIDs)
        let known = Set((content?.windows ?? []).map(\.windowID))
        if !needed.isSubset(of: known) || Date().timeIntervalSince(contentDate) > 5 { refresh() }
        guard let content else { return }

        for (id, t) in targets {
            if let r = replicas[id] {
                guard !r.updating else { continue }
                if r.bounds != t.win.bounds || r.excluded != overlayIDs.union([id]) {
                    update(r, id: id, bounds: t.win.bounds, overlayIDs: overlayIDs, content: content)
                }
            } else if !starting.contains(id), replicas.count + starting.count < Self.maxReplicas {
                start(id: id, win: t.win, view: t.view, overlayIDs: overlayIDs, content: content)
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
        let s = scale(of: display)
        cfg.sourceRect = CGRect(x: bounds.minX - display.frame.minX, y: bounds.minY - display.frame.minY,
                                width: bounds.width, height: bounds.height)
        cfg.width = max(Int(bounds.width * s), 2)
        cfg.height = max(Int(bounds.height * s), 2)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        return cfg
    }

    private func filter(display: SCDisplay, excluding ids: Set<CGWindowID>, content: SCShareableContent) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: content.windows.filter { ids.contains($0.windowID) })
    }

    private func start(id: CGWindowID, win: WinInfo, view: NSView, overlayIDs: Set<CGWindowID>, content: SCShareableContent) {
        guard let disp = display(for: win.bounds, in: content) else { return }
        let excluded = overlayIDs.union([id])
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

    private func update(_ r: Replica, id: CGWindowID, bounds: CGRect, overlayIDs: Set<CGWindowID>, content: SCShareableContent) {
        guard let disp = display(for: bounds, in: content) else { return }
        r.updating = true
        let excluded = overlayIDs.union([id])
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
